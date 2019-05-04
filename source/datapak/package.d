module datapak;

public import vfile;
import bindbc.zstandard.zstd;
import etc.c.zlib;
import std.digest;
import std.digest.murmurhash;
import std.digest.md;
import std.digest.crc;
import std.bitmanip;
import std.stdio;
import std.string : toStringz, fromStringz;

/**
 * DataPak (*.dpk) is mainly intended as a compression method for application assets. Technically it can store folder info,
 * but the fixed filename length is shorter to save some extra space. There's some support for expanding the path, but
 * currently unimplemented.
 * 
 * General layout of a file:
 * <ul>
 * <li>DataPak signature</li>
 * <li>Header</li>
 * <li>Extension area. Ignored by default, handling must be implemented by whoever wants to use it. Can be compressed alongside with the main
 * data to save some space (not recommended if it's needed for compression, e.g. dictionaries), but only if the index field is also compressed.</li>
 * <li>Array of DataPak indexes. Each entry can have some extension. Can be compressed alongside with the main data to save some space.</li>
 * <li>CRC32 checksum at the begining of compressed block or at the end of file information description table.</li>
 * <li>Data</li>
 * </ul>
 */
public class DataPak{
	///Every DataPak file begins with this.
	///The dot will be replaced with numbers if I ever decide to make any upgrades to the format
	static enum char[8] SIGNATURE = "DataPak.";		
	/**
	 * Default compression methods for the file.
	 */
	enum CompressionMethod : char[8]{
		uncompressed		=	"UNCMPRSD",
		deflate				=	"ZLIB    ",			
		zstandard			=	"ZSTD    ",			
		//the following algorithms are not yet implemented, but probably will be
		lz4					=	"LZ4     "
	}
	/**
	 * Selects between checksums.
	 * Please note that the more bytes the checksum needs, the less will be left for the filename.
	 * Values between 32-63 can be used for custom implementations.
	 */
	public enum ChecksumType : ubyte{
		none				=	0,
		ripeMD				=	1,
		murmurhash32_32		=	2,
		murmurhash128_32	=	3,
		murmurhash128_64	=	4,
		sha224				=	5,
		sha256				=	6,
		sha384				=	7,
		sha512				=	8,
		sha512_224			=	9,
		sha512_256			=	10,
		md5					=	11,
		crc32				=	12,
		crc64				=	13,///ISO only!

	}
	/**
	 * Stores the length of each checksum result
	 */
	package static immutable ubyte[14] CHECKSUM_LENGTH = [0, 20, 4, 16, 16, 28, 32, 48, 64, 64, 64, 16, 4, 8];
	/**
	 * Stores important informations about the file.
	 */
	public struct Header{
	align(1):
		ulong		indexSize;		///Size of the index field in bytes, including the extension fields
		ulong		decompSize;		///Total decompressed size
		char[8]		compMethod;		///Compression method stored as a string
		uint		extFieldSize;	///Extension area size
		uint		numOfIndexes;	///Total number of file indexes
		mixin(bitfields!(
			bool, "compIndex", 		1,	///If high, the idexes will be compressed
			bool, "compExtField", 	1,	///If high, the extension field will be compressed
			ubyte, "checksumType",	6,	///Type of checksum for the files
			ubyte, "compLevel",		6,	///Compression level if needed
			uint, "",				18,	///Reserved for future use
		));
		//uint		padding;
	}
	/**
	 * Index representing data for a file.
	 */
	public struct Index{
	align(1):
		ulong 		offset;			///Points to where the file begins in the decompressed stream
		ushort		extFieldSize;	///Extension area size for the index
		ushort		sizeH;			///The upper 16 bits of the file's size
		uint		sizeL;			///The lower 32 bits of the file's size
		char[112]	field;			///Name of the file terminated with a null character + checksum in the end
		///Returns the filename into a string
		public @property string filename() @safe pure nothrow{
			string result;
			size_t pos;
			while(field.length > pos && field[pos] != 0xFF){
				result ~= field[pos];
				pos++;
			}
			return result;
		}
		///Sets the filename
		public @property string filename(string val) @safe @nogc pure nothrow{
			/*for(int i ; i < val.length && i < field.length ; i++){
				field[i] = val[i];
			}*/
			foreach(i , c ; val){
				field[i] = c;
			}
			return val;
		}
		///Returns the checksum/hash
		public ubyte[N] checksum(int N = 16)() @safe @nogc pure nothrow{
			ubyte[N] result;
			for(int i ; i < N ; i++){
				result[i] = field[field.length - N + i];
			}
			return result;
		}
		///Sets the checksum/hash
		public ubyte[N] checksum(int N = 16)(ubyte[N] val) @safe @nogc pure nothrow{
			for(int i ; i < N ; i++){
				field[field.length - N + i] = val[i];
			}
			return val;
		}
	}
	protected Header header;
	protected File file;
	protected Index[] indexes;
	protected string[] paths;			///Only used during compression
	protected uint nextIndex;
	protected ubyte[] extField;
	protected ubyte[][uint] indexExtFields;
	protected bool readOnly, createNew;
	protected void* compStream;
	protected ubyte[] readBuf, compBuf;
	protected ZSTD_inBuffer inBuff;
	protected ZSTD_outBuffer outBuff;
	protected size_t prevOutPos;		///0 if no data left from previous decompression
	protected ulong compPos, compPos0;	///Current position of data; position of all currently decompressed data

	public pure void delegate(size_t pos) progress;	///Called to inform host on decompression process (will be replaced with something more useful in the future)

	public static bool enableThrowOnChecksumError;	///Doesn't throw on errors, returns data regardless of error
	/**
	 * Loads a DataPak file from disk for reading.
	 */
	public this(string filename){
		this(File(filename));
		readOnly = true;
	}
	///Ditto
	public this(File f){
		CRC32 chkSmCalc = CRC32();
		ubyte[4] crc;
		char[] signature;
		signature.length = SIGNATURE.length;
		signature = f.rawRead(signature);
		//check for correct file signature
		//if(signature != SIGNATURE)
		foreach(i ,c ; signature)
			if(SIGNATURE[i] != c)
				throw new Exception("File isn't DataPak file");
		chkSmCalc.put(reinterpretCastA!ubyte(signature));
		readBuf.length = Header.sizeof;
		readBuf = f.rawRead(readBuf);
		header = reinterpretGet!Header(readBuf);
		//ubyte[4] chkSm = header.checksum;
		//header.checksum = [0x0, 0x0, 0x0, 0x0];
		//readBuf.length -= 4;
		//readBuf.length += 4;
		file = f;
		chkSmCalc.put(readBuf);
		if(header.extFieldSize){
			if(!header.compExtField){
				extField.length = header.extFieldSize;
				//f.rawRead(extField);
				extField = f.rawRead(extField);
			}else{
				initDecomp;
				f.rawRead(crc);
				extField = decompressFromFile(header.extFieldSize);
			}
			chkSmCalc.put(extField);
		}
		if(!header.compIndex){
			indexes.length = header.numOfIndexes;
			readBuf.length = Index.sizeof;
			for(int i; i < indexes.length; i++){
				//fread(readBuf.ptr, readBuf.length, 1, f);
				readBuf = f.rawRead(readBuf);
				indexes[i] = reinterpretGet!Index(readBuf);
				chkSmCalc.put(readBuf);
				if(indexes[i].extFieldSize){
					readBuf.length = indexes[i].extFieldSize;
					readBuf = f.rawRead(readBuf);
					chkSmCalc.put(readBuf);
					readBuf.length = Index.sizeof;
					indexExtFields[i] = readBuf.dup;
				}
			}
			f.rawRead(crc);
		}else{
			if(!header.compExtField)
				f.rawRead(crc);
			initDecomp;
			ubyte[] temp = decompressFromFile(header.indexSize);
			ubyte* tempPtr = temp.ptr;
			chkSmCalc.put(temp);
			for(int i; i < indexes.length; i++){
				indexes[i] = *(cast(Index*)(cast(void*)tempPtr));
				tempPtr += Index.sizeof;
				if(indexes[i].extFieldSize){
					indexExtFields[i] = tempPtr[0..indexes[i].extFieldSize].dup;
					tempPtr += indexes[i].extFieldSize;
				}
			}
		}

		const ubyte[4] checksum = chkSmCalc.finish();
		if(crc != checksum && enableThrowOnChecksumError){
			throw new BadChecksumException("CRC32 error in header/index");
		}
		
	}
	/**
	 * Creates a DataPak file from scratch.
	 */
	this(Header header, string targetName, ubyte[] extField = []){
		file = File(targetName, "wb");
		this.header = header;
		createNew = true;
	}
	~this(){
		//fclose(file);
		//deinitialize compression
		switch(header.compMethod){
			case CompressionMethod.zstandard:
				if(createNew){
					ZSTD_freeCStream(cast(ZSTD_CStream*)compStream);
				}else{
					ZSTD_freeDStream(cast(ZSTD_DStream*)compStream);
				}
				break;
			default:	
				break;
		}
	}
	/**
	 * Adds a file to be compressed later.
	 * Returns the created index for it.
	 */
	public Index addFile(string filename, string newName = null, ubyte[] indexExtField = []){
		Index result;
		if(!newName.length){
			newName = filename;
		}
		result.filename = newName;

		ubyte[] buffer;
		buffer.length = 32*1024;
		File f = File(filename);
		result.sizeL = cast(uint)(f.size);
		result.sizeH = cast(ushort)(f.size>>32);
		//Calculate checksums if needed
		size_t remain = cast(size_t)f.size;
		switch(header.checksumType){
			case ChecksumType.murmurhash32_32:
				MurmurHash3!(32,32) checksum = MurmurHash3!(32, 32)(0x66_69_6c_65);
				while(remain > buffer.length){
					f.rawRead(buffer);
					checksum.put(buffer);
					remain -= remain >= buffer.length ? buffer.length : remain;
				}
				if(remain){
					buffer.length = remain;
					f.rawRead(buffer);
					checksum.put(buffer);
				}
				checksum.finalize();
				const ubyte[4] chksRes = checksum.getBytes;
				result.checksum(chksRes);
				break;
			case ChecksumType.murmurhash128_32:
				MurmurHash3!(128,32) checksum = MurmurHash3!(128, 32)(0x66_69_6c_65);
				while(remain > buffer.length){
					f.rawRead(buffer);
					checksum.put(buffer);
					remain -= remain >= buffer.length ? buffer.length : remain;
				}
				if(remain){
					buffer.length = remain;
					f.rawRead(buffer);
					checksum.put(buffer);
				}
				checksum.finalize();
				const ubyte[16] chksRes = checksum.getBytes;
				result.checksum(chksRes);
				break;
			case ChecksumType.murmurhash128_64:
				MurmurHash3!(128,64) checksum = MurmurHash3!(128, 64)(0x66_69_6c_65);
				while(remain > buffer.length){
					f.rawRead(buffer);
					checksum.put(buffer);
					remain -= remain >= buffer.length ? buffer.length : remain;
				}
				if(remain){
					buffer.length = remain;
					f.rawRead(buffer);
					checksum.put(buffer);
				}
				checksum.finalize();
				const ubyte[16] chksRes = checksum.getBytes;
				result.checksum(chksRes);
				break;
			default:
				break;
		}
		result.offset = compPos;
		compPos += f.size;
		result.extFieldSize = cast(ushort)indexExtField.length;
		indexes ~= result;
		if(indexExtField.length)
			indexExtFields[cast(uint)(indexes.length - 1)] = indexExtField;
		header.decompSize += f.size;
		header.indexSize += Index.sizeof + indexExtField.length;
		header.numOfIndexes = cast(uint)indexes.length;
		return result;
	}
	/**
	 * Initializes compression.
	 */
	protected void initComp(){
		if(compStream) return;
		switch(header.compMethod){
			case CompressionMethod.uncompressed:
				break;
			case CompressionMethod.zstandard:
				compStream = ZSTD_createCStream;
				const size_t result = ZSTD_initCStream(cast(ZSTD_CStream*)compStream, header.compLevel);
				readBuf.length = result;
				inBuff = ZSTD_inBuffer(readBuf.ptr, readBuf.length, 0);
				compBuf.length = ZSTD_CStreamOutSize();
				outBuff = ZSTD_outBuffer(compBuf.ptr, compBuf.length, 0);
				break;
			default:
				throw new Exception("Unknown compression method");
		}
	}
	/**
	 * Initializes decompression.
	 */
	protected void initDecomp(){
		if(compStream) return;
		switch(header.compMethod){
			case CompressionMethod.uncompressed:
				break;
			case CompressionMethod.zstandard:
				compStream = ZSTD_createDStream;
				const size_t result = ZSTD_initDStream(cast(ZSTD_DStream*)compStream);
				readBuf.length = result;
				inBuff = ZSTD_inBuffer(readBuf.ptr, readBuf.length, 0);
				compBuf.length = ZSTD_DStreamOutSize();
				outBuff = ZSTD_outBuffer(compBuf.ptr, compBuf.length, 0);
				break;
			default:
				throw new Exception("Unknown compression method");
		}
	}
	/**
	 * Returns a given index.
	 */
	public Index getIndex(uint i){
		if(i >= indexes.length)
			return Index.init;
		else
			return indexes[i];
	}
	/**
	 * Returns the index of next file.
	 */
	public Index getNextIndex(){
		if(nextIndex >= indexes.length)
			return Index.init;
		else
			return indexes[nextIndex];
	}
	/**
	 * Returns the next file as a VFile.
	 */
	/+public VFile getNextAsVFile(){
		VFile result = VFile.__ctor!ubyte(getNextAsArray);
		return result;
	}+/
	/**
	 * Returns the next file as an ubyte[] array.
	 */
	public ubyte[] getNextAsArray(){
		if(nextIndex >= indexes.length)
			return [];
		static if(size_t.sizeof == 4)
			ubyte[] result = decompressFromFile(indexes[nextIndex].sizeL);
		else{
			ubyte[] result = decompressFromFile(cast(ulong)indexes[nextIndex].sizeL | cast(ulong)indexes[nextIndex].sizeH<<32);
		}

		nextIndex++;
		return result;
	}
	/**
	 * Checks the integrity of a file.
	 */
	protected bool checkFile(ubyte[] data, ubyte[] checksum){
		switch(header.checksumType){
			case ChecksumType.murmurhash32_32:
				MurmurHash3!(32,32) chkCalc = MurmurHash3!(32, 32)(0x66_69_6c_65);
				chkCalc.put(data);
				const ubyte[4] result = chkCalc.finish;
				if(result != checksum)
					return false;
				return true;
			case ChecksumType.murmurhash128_32:
				MurmurHash3!(128,32) chkCalc = MurmurHash3!(128, 32)(0x66_69_6c_65);
				chkCalc.put(data);
				const ubyte[16] result = chkCalc.finish;
				if(result != checksum)
					return false;
				return true;
			case ChecksumType.murmurhash128_64:
				MurmurHash3!(128,64) chkCalc = MurmurHash3!(128, 64)(0x66_69_6c_65);
				chkCalc.put(data);
				const ubyte[16] result = chkCalc.finish;
				if(result != checksum)
					return false;
				return true;
			default:
				return true;
		}
	}
	/**
	 * Begins compression into file.
	 */
	public void finalize(){
		CRC32 chkSmCalc = CRC32();
		file.rawWrite(SIGNATURE);
		chkSmCalc.put(reinterpretCast!ubyte(SIGNATURE));
		file.rawWrite([header]);
		chkSmCalc.put(reinterpretCast!ubyte(header));
		if(!header.compIndex && !header.compExtField){
			if(extField.length)
				file.rawWrite(extField);
				chkSmCalc.put(extField);
			foreach(n, i; indexes){
				file.rawWrite([i]);
				chkSmCalc.put(reinterpretCast!ubyte(i));
				if(indexExtFields.get(cast(uint)n, null) !is null){
					file.rawWrite(indexExtFields[cast(uint)n]);
					chkSmCalc.put(indexExtFields[cast(uint)n]);
				}
			}
			const ubyte[4] checksum = chkSmCalc.finish;
			file.rawWrite(checksum);
		}else
			throw new Exception("Feature not yet implemented");
		//write each files in order of access
		foreach(n, i; indexes){
			this.compress(i.filename, i);
		}
	}
	/**
	 * Compresses a single file into the stream.
	 */
	protected void compress(string source, Index index){
		File src = File(source, "rb");
		switch(header.compMethod){
			case CompressionMethod.uncompressed://in this case, we just want to copy the raw data into the file
				ubyte[] buffer;
				buffer.length = 32*1024;
				/*while(src.tell + buffer.length >= src.size){
					src.rawRead(buffer);
					file.rawWrite(buffer);
				}*/
				do{
					buffer = src.rawRead(buffer);
					file.rawWrite(buffer);
				}while(buffer.length == 32.1024);
				/*if(src.size - src.tell){
					buffer.length = cast(size_t)(src.size - src.tell);
					src.rawRead(buffer);
					file.rawWrite(buffer);
				}*/
				break;
			case CompressionMethod.zstandard:
				size_t readSize, compSize;
				do{
					if (src.tell + readBuf.length >= src.size){
						readSize = readBuf.length;
						src.rawRead(readBuf);
					} else if (src.size - src.tell){
						readSize = cast(size_t)(src.size - src.tell);
						src.rawRead(readBuf[0..readSize]);
					}
					inBuff.pos = 0;
					inBuff.size = readSize;
					while(inBuff.pos < inBuff.size){
						compSize = ZSTD_compressStream(cast(ZSTD_CStream*)compStream, &outBuff, &inBuff);
						if(ZSTD_isError(compSize)){
							throw new CompressionException(cast(string)(fromStringz(ZSTD_getErrorName(compSize))));
						}
						//fwrite(outBuff.dst, compSize, 1, file);
						file.rawWrite(outBuff.dst[0..compSize]);
						outBuff.pos = 0;
					}
					inBuff.size = readBuf.length;
				}while(readSize);
				//Flush to disk
				compSize = ZSTD_flushStream(cast(ZSTD_CStream*)compStream, &outBuff);
				if(ZSTD_isError(compSize)){
					throw new CompressionException(cast(string)fromStringz(ZSTD_getErrorName(compSize)));
				}
				if(compSize){
					
				}else{
					//fwrite(outBuff.dst, outBuff.pos, 1, file);
					file.rawWrite(outBuff.dst[0..outBuff.pos]);
				}
				outBuff.pos = 0;
				
				break;
			case CompressionMethod.deflate:
				break;
			default:
				//fclose(src);
				throw new Exception("Unknown compression method");
		}
		//fclose(src);
	}
	/**
	 * Decompresses a given amount from the file from the current position.
	 */
	protected ubyte[] decompressFromFile(const size_t amount){
		ubyte[] output;
		size_t curAmount;
		compPos += amount;
		switch(header.compMethod){
			case CompressionMethod.uncompressed://in this case, we just want to read regular data from file
				output.length = amount;
				//fread(output.ptr, output.length, 1, file);
				file.rawRead(output);
				break;
			case CompressionMethod.zstandard:
				//Try if we can get away with setting the output buffer the exact size a file needed, so we can avoid issues from overlapping decompression
				output.length = amount;
				ZSTD_outBuffer localOutBuf = ZSTD_outBuffer(output.ptr, output.length, 0);
				size_t prevPos;
				do{
					if(inBuff.size == inBuff.pos){
						inBuff.pos = 0;
						//fread(readBuf.ptr, readBuf.length, 1, file);
						file.rawRead(readBuf);
					}
					const size_t result = ZSTD_decompressStream(cast(ZSTD_DStream*)compStream, &localOutBuf, &inBuff);
					if(ZSTD_isError(result)){
						throw new CompressionException(cast(string)(fromStringz(ZSTD_getErrorName(result))));
					}else{
						compPos += localOutBuf.pos - prevPos;
						prevPos = localOutBuf.pos;
					}
				} while (localOutBuf.size > localOutBuf.pos);
				break;
			case CompressionMethod.deflate:
				break;
			default:
				throw new Exception("Unknown compression method");
		}
		return output;
	}
}

unittest{
	DataPak.Index index;
	index.filename = "something";
	writeln(index.field);
	assert(index.filename == "something");
}
/**
 * Default extension for adding general support for using it as a regular file archival tool
 */
struct DataPak_OSExt{
align(1):
	char[6]		id = "OSExt ";			///Identifies that this field is a DataPak_OSExt struct
	ushort		size = 256;				///Size of this field
	char[160]	path;					///Stores the relative path of the file
	char[32]	ownerUserID;			///Owner's ID on POSIX systems
	char[32]	ownerUserGroup;			///Owner's group on POSIX systems
	ulong		creationDate;			///Creation date in 64 bit POSIX time format
	ulong		modifyDate;				///Modification date in 64 bit POSIX time format
	ulong		field;					///Unused by default, can store attributes if needed
}
/**
 * Reinterprets an array as the requested type.
 */
package T[] reinterpretCastA(T,U)(U[] input) pure @trusted{
	T[] _reinterpretCastA(U[] i) pure @system{
		return cast(T[])(cast(void[])input);
	}
	if ((U.sizeof * input.length) % T.sizeof == 0)
		return _reinterpretCastA(input);
	else
		throw new Exception("Reinterpretation error!");
}
/**
 * Reinterprets an array as the requested type.
 */
package T[] reinterpretCast(T,U)(U input) pure @trusted{
	T[] _reinterpretCast(U i) pure @system{
		return cast(T[])(cast(void[])[input]);
	}
	if (U.sizeof % T.sizeof == 0)
		return _reinterpretCast(input);
	else
		throw new Exception("Reinterpretation error!");
	
}
/**
 * Gets a certain type from an array.
 */
package T reinterpretGet(T,U)(U[] input) pure @trusted{
	T _reinterpretGet(U[] i) pure @system{
		return *(cast(T*)(cast(void*)i.ptr));
	}
	if (input.length == T.sizeof)
		return _reinterpretGet(input);
	else
		throw new Exception("Reinterpretation error!");
}
/**
 * Thrown on checksum errors
 */
public class BadChecksumException : Exception{
	@nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
    }

    @nogc @safe pure nothrow this(string msg, Throwable nextInChain, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, nextInChain);
    }
}
/**
 * Thrown on compression errors
 */
public class CompressionException : Exception{
	@nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
    }

    @nogc @safe pure nothrow this(string msg, Throwable nextInChain, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, nextInChain);
    }
}