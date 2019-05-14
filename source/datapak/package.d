module datapak;

public import vfile;
import bindbc.zstandard.zstd;
import zlib = etc.c.zlib;
import std.digest;
import std.digest.murmurhash;
import std.digest.md;
import std.digest.sha;
import std.digest.ripemd;
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
		crc64ISO			=	13,
		crc64ECMA			=	14
	}
	/**
	 * Stores the length of each checksum result
	 */
	package static immutable ubyte[15] CHECKSUM_LENGTH = [0, 20, 4, 16, 16, 28, 32, 48, 64, 28, 32, 16, 4, 8, 8];
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
	protected zlib.z_stream deflateStream;
	protected ubyte[] readBuf, compBuf;
	protected ZSTD_inBuffer inBuff;
	protected ZSTD_outBuffer outBuff;
	protected size_t prevOutPos;		///0 if no data left from previous decompression
	protected ulong compPos, compPos0;	///Current position of data; position of all currently decompressed data

	public pure void delegate(size_t pos) progress;	///Called to inform host on decompression process (will be replaced with something more useful in the future)

	//Configuration area, might be replaced with individual values instead of static ones.
	public static bool enableHeaderChecksumError = true;	///If false, then it'll disable throw on header checksum mismatch
	public static bool enableFileChecksumError = true;		///If false, then it'll disable throw on file checksum mismatch and calculation (useful when dealing with complex hash algorithms not designed for quick checksums)
	public static size_t readBufferSize = 32 * 1024; ///Sets the read buffer size of all instances (default is 32kB)
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
		initDecomp;
		if(header.extFieldSize){
			if(!header.compExtField){
				extField.length = header.extFieldSize;
				//f.rawRead(extField);
				extField = f.rawRead(extField);
			}else{
				
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
		if(crc != checksum && enableHeaderChecksumError){
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
		initComp;
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
			case CompressionMethod.deflate:
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
		ubyte[N] _generateChecksum(CHKSM, size_t N)(CHKSM checksum){
			while(buffer.length){
				buffer = f.rawRead(buffer);
				checksum.put(buffer);
			}
			//checksum.finalize();
			return checksum.finish();
		}
		switch(header.checksumType){
			case ChecksumType.crc32:
				result.checksum(_generateChecksum!(CRC32, 4)(CRC32()));
				break;
			case ChecksumType.crc64ECMA:
				result.checksum(_generateChecksum!(CRC64ECMA, 8)(CRC64ECMA()));
				break;
			case ChecksumType.crc64ISO:
				result.checksum(_generateChecksum!(CRC64ISO, 8)(CRC64ISO()));
				break;
			case ChecksumType.md5:
				result.checksum(_generateChecksum!(MD5, 16)(MD5()));
				break;
			case ChecksumType.ripeMD:
				result.checksum(_generateChecksum!(RIPEMD160, 20)(RIPEMD160()));
				break;
			case ChecksumType.sha224:
				result.checksum(_generateChecksum!(SHA224, 28)(SHA224()));
				break;
			case ChecksumType.sha256:
				result.checksum(_generateChecksum!(SHA256, 32)(SHA256()));
				break;
			case ChecksumType.sha384:
				result.checksum(_generateChecksum!(SHA384, 48)(SHA384()));
				break;
			case ChecksumType.sha512:
				result.checksum(_generateChecksum!(SHA512, 64)(SHA512()));
				break;
			case ChecksumType.sha512_224:
				result.checksum(_generateChecksum!(SHA512_224, 28)(SHA512_224()));
				break;
			case ChecksumType.sha512_256:
				result.checksum(_generateChecksum!(SHA512_256, 32)(SHA512_256()));
				break;
			case ChecksumType.murmurhash32_32:
				result.checksum(_generateChecksum!(MurmurHash3!(32, 32), 4)(MurmurHash3!(32, 32)(0x66_69_6c_65)));
				break;
			case ChecksumType.murmurhash128_32:
				result.checksum(_generateChecksum!(MurmurHash3!(128, 32), 16)(MurmurHash3!(128, 32)(0x66_69_6c_65)));
				break;
			case ChecksumType.murmurhash128_64:
				result.checksum(_generateChecksum!(MurmurHash3!(128, 64), 16)(MurmurHash3!(128, 64)(0x66_69_6c_65_66_69_6c_65L)));
				break;
			default:
				break;
		}
		result.offset = compPos;
		compPos += f.size;
		result.extFieldSize = cast(ushort)indexExtField.length;
		if(indexExtField.length)
			indexExtFields[cast(uint)indexes.length] = indexExtField;
		indexes ~= result;
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
				compStream = ZSTD_createCStream();
				//const size_t result = ZSTD_initCStream(cast(ZSTD_CStream*)compStream, header.compLevel);
				readBuf.length = readBufferSize;
				ZSTD_CCtx_reset(cast(ZSTD_CStream*)compStream, ZSTD_ResetDirective.ZSTD_reset_session_only);
				ZSTD_CCtx_setParameter(cast(ZSTD_CStream*)compStream, ZSTD_cParameter.ZSTD_c_compressionLevel, header.compLevel);
				inBuff = ZSTD_inBuffer(readBuf.ptr, readBuf.length, 0);
				//compBuf.length = ZSTD_CStreamOutSize();
				compBuf.length = readBufferSize;
				outBuff = ZSTD_outBuffer(compBuf.ptr, compBuf.length, 0);
				break;
			case CompressionMethod.deflate:
				if(zlib.Z_OK != zlib.deflateInit(&deflateStream, header.compLevel))
					throw new CompressionException("Failed to initialize deflate.");
				readBuf.length = readBufferSize;
				deflateStream.avail_in = cast(uint)readBuf.length;
				deflateStream.next_in = readBuf.ptr;
				compBuf.length = readBufferSize;
				deflateStream.avail_out = cast(uint)compBuf.length;
				deflateStream.next_out = compBuf.ptr;
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
				compStream = ZSTD_createDStream();
				ZSTD_initDStream(cast(ZSTD_DStream*)compStream);
				//writeln(result);
				readBuf.length = readBufferSize;
				inBuff = ZSTD_inBuffer(readBuf.ptr, readBuf.length, 0);
				//compBuf.length = ZSTD_DStreamOutSize();
				//outBuff = ZSTD_outBuffer(compBuf.ptr, compBuf.length, 0);
				break;
			case CompressionMethod.deflate:
				if(zlib.Z_OK != zlib.inflateInit(&deflateStream))
					throw new CompressionException("Failed to initialize deflate");
				readBuf.length = readBufferSize;
				deflateStream.next_in = readBuf.ptr;
				deflateStream.avail_in = cast(uint)readBuf.length;
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
	 * Checks the integrity of a file against a hash or checksum.
	 */
	protected bool checkFile(ubyte[] data, ubyte[] checksum){
		bool _checkFile (CHKSM)(CHKSM chkCalc) {
			chkCalc.put(data);
			immutable auto result = chkCalc.finish;
			if (result == checksum)
				return true;
			else
				return false;
		}
		switch(header.checksumType){
			case ChecksumType.ripeMD:
				return _checkFile(RIPEMD160());
			case ChecksumType.md5:
				return _checkFile(MD5());
			case ChecksumType.crc32:
				return _checkFile(CRC32());
			case ChecksumType.crc64ISO:
				return _checkFile(CRC64ISO());
			case ChecksumType.crc64ECMA:
				return _checkFile(CRC64ECMA());
			case ChecksumType.sha224:
				return _checkFile(SHA224());
			case ChecksumType.sha256:
				return _checkFile(SHA256());
			case ChecksumType.sha384:
				return _checkFile(SHA384());
			case ChecksumType.sha512:
				return _checkFile(SHA512());
			case ChecksumType.sha512_224:
				return _checkFile(SHA512_224());
			case ChecksumType.sha512_256:
				return _checkFile(SHA512_256());
			case ChecksumType.murmurhash32_32:
				return _checkFile(MurmurHash3!(32,32)(0x66_69_6c_65));
			case ChecksumType.murmurhash128_32:
				return _checkFile(MurmurHash3!(128,32)(0x66_69_6c_65));
			case ChecksumType.murmurhash128_64:
				return _checkFile(MurmurHash3!(128,64)(0x66_69_6c_65_66_69_6c_65L));
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
		switch (header.compMethod) {
			case CompressionMethod.zstandard:
				size_t remaining;
				do {
					remaining = ZSTD_compressStream2(cast(ZSTD_CStream*)compStream, &outBuff, &inBuff, ZSTD_EndDirective.ZSTD_e_end);
					if(outBuff.size)
						file.rawWrite(outBuff.dst[0..outBuff.pos]);
					outBuff.pos = 0;
				} while (remaining);
				break;
			case CompressionMethod.deflate:
				int result;
				//finish compression and flush whatever is remaining in the buffers
				do {
					result = zlib.deflate(&deflateStream, zlib.Z_FINISH);
					if (!deflateStream.avail_out) {	//write to disk if output buffer is full
						file.rawWrite(compBuf);
						deflateStream.avail_out = cast(uint)compBuf.length;
						deflateStream.next_out = compBuf.ptr;
					}
				} while (result != zlib.Z_STREAM_END);
				if (deflateStream.avail_out != compBuf.length) {
					file.rawWrite(compBuf[0..$-deflateStream.avail_out]);
					deflateStream.avail_out = cast(uint)compBuf.length;
					deflateStream.next_out = compBuf.ptr;
				}
				break;
			default:
				break;
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
				buffer.length = readBufferSize;
				/*while(src.tell + buffer.length >= src.size){
					src.rawRead(buffer);
					file.rawWrite(buffer);
				}*/
				do{
					buffer = src.rawRead(buffer);
					if(buffer.length)
						file.rawWrite(buffer);
				}while(buffer.length == readBufferSize);
				/*if(src.size - src.tell){
					buffer.length = cast(size_t)(src.size - src.tell);
					src.rawRead(buffer);
					file.rawWrite(buffer);
				}*/
				break;
			case CompressionMethod.zstandard:
				size_t compSize;
				readBuf.length = readBufferSize;
				do {
					readBuf = src.rawRead(readBuf);
					inBuff.src = readBuf.ptr;
					inBuff.pos = 0;
					inBuff.size = readBuf.length;
					while (inBuff.pos < inBuff.size) {
						compSize = ZSTD_compressStream2(cast(ZSTD_CStream*)compStream, &outBuff, &inBuff, ZSTD_EndDirective.ZSTD_e_continue);
						if (ZSTD_isError(compSize)) {
							throw new CompressionException(cast(string)(fromStringz(ZSTD_getErrorName(compSize))));
						}
						//writeln(source, ": ", compSize,"; ;",outBuff.pos);
						//fwrite(outBuff.dst, compSize, 1, file);
						if(outBuff.pos)
							file.rawWrite(outBuff.dst[0..outBuff.pos]);
						outBuff.pos = 0;
					}
					inBuff.size = readBuf.length;
				} while(readBuf.length == readBufferSize);
				//Flush to disk
				do {
					compSize = ZSTD_compressStream2(cast(ZSTD_CStream*)compStream, &outBuff, &inBuff, ZSTD_EndDirective.ZSTD_e_flush);
					//writeln(source, ": ", compSize,"; ",outBuff.pos);
					if(ZSTD_isError(compSize))
						throw new CompressionException(cast(string)fromStringz(ZSTD_getErrorName(compSize)));
					if(outBuff.pos)
						file.rawWrite(outBuff.dst[0..outBuff.pos]);
					outBuff.pos = 0;
				} while(compSize);
				
				outBuff.pos = 0;
				
				break;
			case CompressionMethod.deflate:
				readBuf.length = readBufferSize;
				do {
					readBuf = src.rawRead(readBuf);
					deflateStream.avail_in = cast(uint)readBuf.length;
					deflateStream.next_in = readBuf.ptr;
					do {
						int result;
						if(readBuf.length == readBufferSize)
							result = zlib.deflate(&deflateStream, zlib.Z_FULL_FLUSH);
						else
							result = zlib.deflate(&deflateStream, zlib.Z_SYNC_FLUSH);
						if (result < 0)
							throw new CompressionException(cast(string)(fromStringz(deflateStream.msg)));
						if (!deflateStream.avail_out) {	//write to disk if output buffer is full
							file.rawWrite(compBuf);
							deflateStream.avail_out = cast(uint)compBuf.length;
							deflateStream.next_out = compBuf.ptr;
						}
					} while (deflateStream.avail_in);
				} while (readBuf.length == readBufferSize);
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
	protected ubyte[] decompressFromFile (const size_t amount) {
		ubyte[] output;
		output.length = amount;
		//size_t curAmount;
		//writeln("compPos: ",compPos);
		switch (header.compMethod) {
			case CompressionMethod.uncompressed://in this case, we just want to read regular data from file
				
				//fread(output.ptr, output.length, 1, file);
				output = file.rawRead(output);
				if(output.length != amount)
					throw new Exception("EOF reached earlier than expected from header/indexing");
				break;
			case CompressionMethod.zstandard:
				//Try if we can get away with setting the output buffer the exact size a file needed, so we can avoid issues from overlapping decompression
				//output.length = amount;
				ZSTD_outBuffer localOutBuf = ZSTD_outBuffer(output.ptr, output.length, 0);
				//size_t prevPos;
				do {
					if (inBuff.size == inBuff.pos || !compPos) {
						inBuff.pos = 0;
						readBuf = file.rawRead(readBuf);
						inBuff.src = readBuf.ptr;
						inBuff.size = readBuf.length;
					}
					const size_t result = ZSTD_decompressStream(cast(ZSTD_DStream*)compStream, &localOutBuf, &inBuff);
					if(ZSTD_isError(result))
						throw new CompressionException(cast(string)(fromStringz(ZSTD_getErrorName(result))));
					
				} while (localOutBuf.size > localOutBuf.pos);
				break;
			case CompressionMethod.deflate:
				deflateStream.next_out = output.ptr;
				deflateStream.avail_out = cast(uint)output.length;
				int result;
				do {
					if (!deflateStream.avail_in || !compPos) {
						readBuf = file.rawRead(readBuf);
						deflateStream.next_in = readBuf.ptr;
						deflateStream.avail_in = cast(uint)readBuf.length;
					}
					//if(readBuf.length == readBufferSize)
					result = zlib.inflate(&deflateStream, zlib.Z_FULL_FLUSH);
					/+else
						result = zlib.inflate(&deflateStream, zlib.Z_SYNC_FLUSH);+/
					/+if(result < 0)
						throw new CompressionException(cast(string)(fromStringz(deflateStream.msg)));+/
				} while (deflateStream.avail_out);
				break;
			default:
				throw new Exception("Unknown compression method");
		}
		compPos += amount;
		readBuf.length = readBufferSize;
		return output;
	}

	public static void loadZSTD () {
		import bindbc.zstandard.dynload;
		import bindbc.zstandard.config;
		ZSTDSupport result = loadZstandard();
		if (result == ZSTDSupport.noLibrary || result == ZSTDSupport.badLibrary)
			throw new Exception("ZSTD not found!");
	}
	public static void loadZSTD (string lib) {
		import bindbc.zstandard.dynload;
		import bindbc.zstandard.config;
		ZSTDSupport result = loadZstandard(toStringz(lib));
		if (result == ZSTDSupport.noLibrary || result == ZSTDSupport.badLibrary)
			throw new Exception("ZSTD not found!");
	}
}

unittest{
	DataPak.Index index;
	index.filename = "something";
	writeln(index.field);
	assert(index.filename == "something");
}
/**
 * Default extension for adding general support for using it as a regular file archival tool.
 * This does not contain user-privilege settings, those will be relegated to another struct. 
 */
struct DataPak_OSExt {
align(1):
	char[6]		id = "OSExt ";			///Identifies that this field is a DataPak_OSExt struct
	ushort		size = DataPak_OSExt.sizeof;	///Size of this field
	char[200]	nameExt;				///Stores filename extension + relative path
	ulong		creationDate;			///Creation date in 64 bit POSIX time format
	ulong		modifyDate;				///Modification date in 64 bit POSIX time format
	ulong		field;					///Unused by default, can store attributes if needed
	///Sets the name extension of the file
	public string name(string val) @safe @property @nogc nothrow pure{
		for (size_t i ; i < nameExt.length ; i++)
			nameExt[i] = 0xFF;
		foreach (i , c ; val)
			nameExt[i] = c;
		return val;
	}
	///Gets the name extension of the file
	public string name() @safe @property nothrow pure{
		string result;
		size_t pos;
		while(nameExt.length > pos && nameExt[pos] != 0xFF){
			result ~= nameExt[pos];
			pos++;
		}
		return result;
	}
}
/**
 * Default extension for adding support for compression algorithms that support random access
 */
struct DataPak_RandomAccessExt{
align(1):
	char[6]		id = "RandAc";			///Identifies that this field is a DataPak_RandomAccessExt struct
	ushort		size = DataPak_RandomAccessExt.sizeof;	///Size of this field
	ulong		position;				///Position of file
	union{
		ulong[2]	field64;
		uint[4]		field32;
		ushort[8]	field16;
		ubyte[16]	field8;
	}
}
/**
 * Reinterprets an array as the requested type.
 */
package T[] reinterpretCastA(T,U)(U[] input) pure @trusted{
	T[] _reinterpretCastA() pure @system{
		return cast(T[])(cast(void[])input);
	}
	if ((U.sizeof * input.length) % T.sizeof == 0)
		return _reinterpretCastA();
	else
		throw new Exception("Reinterpretation error!");
}
/**
 * Reinterprets an array as the requested type.
 */
package T[] reinterpretCast(T,U)(U input) pure @trusted{
	T[] _reinterpretCast() pure @system{
		return cast(T[])(cast(void[])[input]);
	}
	if (U.sizeof % T.sizeof == 0)
		return _reinterpretCast();
	else
		throw new Exception("Reinterpretation error!");
	
}
/**
 * Gets a certain type from an array.
 */
package T reinterpretGet(T,U)(U[] input) pure @trusted{
	T _reinterpretGet() pure @system{
		return *(cast(T*)(cast(void*)input.ptr));
	}
	if (input.length == T.sizeof)
		return _reinterpretGet();
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