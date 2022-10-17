/*
 * Datapak
 * Created by Laszlo Szeremi in 2019
 *
 * Copyright under Boost Software License
 */

module datapak;

public import vfile;
public import datapak.exceptions;
import bindbc.zstandard.zstd;
import zlib = etc.c.zlib;
import std.digest;
import std.digest.crc;
import std.bitmanip;
import std.stdio;
import std.string : toStringz, fromStringz;
import bitleveld.reinterpret;

/**
 * DataPak (*.dpk) is mainly intended as a compression method for application assets. Technically it can store folder info,
 * but the fixed filename length is shorter to save some extra space alongside with other missing info (creation date, etc).
 * Standard extensions can give these functionalities back.
 * 
 * General layout of a file:
 * 
 * * DataPak signature
 * * Header
 * * Extension area. Certain extensions might help decompress the file (e.g. decompression dictionaries), everything else is ignored
 * here by default, and the end user must implement handling of them.
 * * Array of DataPak indexes. Each entry can have some extension. Can be compressed alongside with the main data to save some space.
 * * CRC32 checksum at the begining of compressed block or at the end of file information description table.
 * * Data chunks
 */
public class DataPak {
	///Every DataPak file begins with this.
	///The dot will be replaced with numbers if I ever decide to make any upgrades to the format
	static enum char[8] SIGNATURE = "DataPak.";
	///Standard extensions recognized by the format.
	enum StandardExtensions : char[8] {
		CompressionDict		=	"CMPRDICT",
		ExtCmprDictFile		=	"CMPRDIxf"
	}
	/**
	 * Default compression methods for the file.
	 */
	enum CompressionMethod : char[8] {
		uncompressed		=	"UNCMPRSD",
		deflate				=	"ZLIB    ",			
		zstandard			=	"ZSTD    ",	
		zstandardWDict		=	"ZSTD+D  ",	
		//the following algorithms are not yet implemented, but probably will be
		lz4					=	"LZ4     "
	}
	/**
	 * Selects between checksums.
	 * Only crc32 and two types of crc64 are supported in the final version.
	 */
	public enum ChecksumType : ubyte{
		none				=	0,
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
	public struct Header {
	align(1):
		ulong		indexSize;		///Size of the index field in bytes, including the extension fields
		char[8]		compMethod;		///Compression method stored as a string
		uint		extFieldSize;	///Extension area size
		uint		numOfIndexes;	///Total number of file indexes
		mixin(bitfields!(
			bool, "compIndex", 		1,	///If high, the idexes will be compressed
			bool, "compExtField", 	1,	///If high, the extension field will be compressed
			ubyte, "checksumType",	6,	///Type of checksum for the files
			ubyte, "compLevel",		6,	///Compression level if needed
			bool, "perFileComp",	1,	///Per-file compression, mainly recommended with dictionary-type compressors
			/**
			 * Sets the limit of the Datapak file.
			 * 0: No limits, only technological ones. File chaining is disabled.
			 * 1: FAT32 limit (4GB).
			 * 2: ISO9660 limit (2GB).
			 * 3-7: 1GB or less, based on the power of two.
			 */
			ubyte, "filesizeLimit",	3,
			ushort, "reserved",		14,	///Reserved for future use
		));
		//uint		padding;
	}
	/**
	 * Header extension field identifiers
	 */
	public struct HeaderExt {
	align(1):
		char[8]		signature;		///Identifier of the extension field.
		uint		size;			///Size of the extension field, including these fields.
	}
	/**
	 * Index representing data for a file.
	 */
	public struct Index {
	align(1):
		/**
		 * Points to where the file begins in the stream.
		 * In case of files compressed at once or uncompressed files, the offset points to the location in the decompressed stream.
		 * In case of individually compressed files, the offset points to the location of the compressed data.
		 */
		ulong 		offset;			
		ulong		uncompSize;			///Uncompressed size of the file
		ulong		compSize;			///Compressed size of the file, or the same as the previous field if uncompressed, or zero if archive is not random access
		uint		extFieldSize;		///Index extension field size
		char[100]	field;				///Name of the file terminated with a null character + checksum in the end (CRC32 or CRC64)
		///Returns the filename into a string
		public @property string filename() @safe pure nothrow {
			string result;
			size_t pos;
			while(field.length > pos && field[pos] != 0){
				result ~= field[pos];
				pos++;
			}
			return result;
		}
		///Sets the filename
		public @property string filename(string val) @safe @nogc pure nothrow {
			foreach(size_t i , char c ; val){
				field[i] = c;
			}
			field[val.length] = 0x00;
			return val;
		}
		///Returns the checksum/hash
		public ubyte[N] checksum(int N = 4)() @safe @nogc pure nothrow {
			ubyte[N] result;
			for(int i ; i < N ; i++){
				result[i] = field[field.length - N + i];
			}
			return result;
		}
		///Sets the checksum/hash
		public ubyte[N] checksum(int N = 4)(ubyte[N] val) @safe @nogc pure nothrow {
			for(int i ; i < N ; i++){
				field[field.length - N + i] = val[i];
			}
			return val;
		}
	}
	/**
	 * Index extension identifier.
	 */
	public struct IndexExt {
	align(1):
		char[6]		signature;		///Identification of the extension field.
		ushort		size;			///Size of this extension field, including these fields.
	}
	protected Header header;			///File header
	protected File file;				///Filestream
	protected Index[] indexes;			///File indexes
	protected string[] paths;			///Only used during compression
	protected uint nextIndex;
	protected ubyte[][] extField;
	protected ubyte[][][uint] indexExtFields;
	protected bool readOnly, createNew;
	protected void* compStream, compDict;
	protected zlib.z_stream deflateStream;
	protected ubyte[] readBuf, compBuf, dictionary;
	protected ZSTD_inBuffer inBuff;
	protected ZSTD_outBuffer outBuff;
	protected size_t prevOutPos;		///0 if no data left from previous decompression
	protected ulong compPos, compPos0;	///Current position of data; position of all currently decompressed data

	public void delegate(size_t pos, size_t total) progress;	///Called to inform host on compression or decompression process
	public void delegate(string filename) currentFile;			///Called to inform host on compression or decompression process
	public void delegate(uint num, ref string filename) nextFile;	///Called to inform host if next file is needed

	//Configuration area, might be replaced with individual values instead of static ones.
	public static bool enableSignatureCheck = true;			///If false, then it'll disable throw on file signature mismatch
	public static bool enableHeaderChecksumError = true;	///If false, then it'll disable throw on header checksum mismatch
	public static bool enableFileChecksumError = true;		///If false, then it'll disable throw on file checksum mismatch and calculation (useful when dealing with complex hash algorithms not designed for quick checksums)
	public static size_t readBufferSize = 32 * 1024; ///Sets the read buffer size of all instances (default is 32kB)
	/**
	 * Loads a DataPak file from disk for reading.
	 */
	public this(string filename) {
		this(File(filename));
		readOnly = true;
	}
	///Ditto
	public this(File f) {
		CRC32 chkSmCalc = CRC32();
		ubyte[4] crc;
		char[] signature;
		signature.length = SIGNATURE.length;
		signature = f.rawRead(signature);
		if(SIGNATURE != signature && enableSignatureCheck)
			throw new Exception("File isn't DataPak file");
		chkSmCalc.put(reinterpretCast!ubyte(signature));
		readBuf.length = Header.sizeof;
		readBuf = f.rawRead(readBuf);
		header = reinterpretGet!Header(readBuf);
		file = f;
		chkSmCalc.put(readBuf);
		
		
		/+if(header.compExtField) {
			initDecomp;
			f.rawRead(crc);
		}+/
		size_t extFieldRemain = cast(size_t)header.extFieldSize;
		size_t extFieldNum;
		while(extFieldRemain) {
			ubyte[] buffer0, buffer1;
			buffer0.length = HeaderExt.sizeof;

			buffer0 = f.rawRead(buffer0);

			const HeaderExt extension = reinterpretGet!HeaderExt(buffer0);
			buffer1.length = extension.size - HeaderExt.sizeof;

			buffer1 = f.rawRead(buffer1);
			switch (extension.signature) {
				case StandardExtensions.CompressionDict:
					dictionary = buffer1;
					break;
				case StandardExtensions.ExtCmprDictFile:
					File dictionaryFile = File(reinterpretCast!char(buffer1).idup);
					dictionary.length = cast(size_t)dictionaryFile.size;
					dictionary = dictionaryFile.rawRead(dictionary);
					break;
				default:
					break;
			}
			extField[extFieldNum] = buffer0 ~ buffer1;

			chkSmCalc.put(extField[extFieldNum]);
			extFieldRemain -= extension.size;
			extFieldNum++;
		}
		
		/+if(header.compIndex) {
			initDecomp;
			f.rawRead(crc);
		}+/
		indexes.length = header.numOfIndexes;
		readBuf.length = Index.sizeof;
		for(uint i; i < indexes.length; i++){
			/+if(header.compIndex) readBuf = decompressFromFile(readBuf.length);
			else +/
			readBuf = f.rawRead(readBuf);
			
			indexes[i] = reinterpretGet!Index(readBuf);
			chkSmCalc.put(readBuf);
				
			extFieldRemain = indexes[i].extFieldSize;
			extFieldNum = 0;
			while (extFieldRemain){
				ubyte[] buffer0, buffer1;
				buffer0.length = IndexExt.sizeof;
				/+if(header.compIndex) buffer0 = decompressFromFile(buffer0.length);
				else+/ 
				buffer0 = f.rawRead(buffer0);

				const IndexExt extension = reinterpretGet!IndexExt(buffer0);
				buffer1.length = extension.size - IndexExt.sizeof;

				/+if(header.compIndex) buffer1 = decompressFromFile(buffer1.length);
				else+/ 
				buffer1 = f.rawRead(buffer1);

				indexExtFields[i][extFieldNum] = buffer0 ~ buffer1;
				extFieldRemain -= extension.size;
				extFieldNum++;
			}
				
		}
		f.rawRead(crc);
		//initDecomp;
		const ubyte[4] checksum = chkSmCalc.finish();
		if(crc != checksum && enableHeaderChecksumError){
			throw new BadChecksumException("CRC32 error in header/index");
		}
		
	}
	/**
	 * Creates a DataPak file from scratch.
	 */
	this(Header header, string targetName, ubyte[][] extField = null) {
		file = File(targetName, "wb");
		this.header = header;
		this.extField = extField;
		createNew = true;
		initComp;
	}
	/** 
	 * 
	 * Params:
	 *   compMethod = 
	 *   targetName = 
	 *   extField = 
	 */
	this(char[8] compMethod, string targetName, ubyte[][] extField = null) {
		file = File(targetName, "wb");
		this.header = Header(0, compMethod, 0, 0);
		foreach (ubyte[] key; extField) {
			this.header.extFieldSize += key.length;
		}
		this.extField = extField;
		createNew = true;
		initComp;
	}
	~this(){
		//fclose(file);
		//deinitialize compression
		switch(header.compMethod){
			case CompressionMethod.zstandard, CompressionMethod.zstandardWDict:
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
	///Returns true if the file is random-access capable
	public @property bool randomAccess() const @nogc @safe pure nothrow {
		if(header.perFileComp) return true;
		else if(header.compMethod == CompressionMethod.uncompressed) return true;
		return false;
	}
	/**
	 * Adds a file to be compressed later.
	 * Returns the created index for it.
	 */
	public Index addFile(string filename, string path, ubyte[][] indexExtField = [][]){
		Index result;
		result.filename = filename;

		ubyte[] buffer;
		buffer.length = 32*1024;
		File f = File(path);
		result.uncompSize = f.size;
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
			default:
				break;
		}
		result.offset = compPos;
		compPos += f.size;
		result.extFieldSize = cast(ushort)indexExtField.length;
		if(indexExtField.length)
			indexExtFields[cast(uint)indexes.length] = indexExtField;
		indexes ~= result;
		paths ~= path;
		//header.decompSize += f.size;
		header.indexSize += Index.sizeof + indexExtField.length;
		header.numOfIndexes = cast(uint)indexes.length;
		return result;
	}
	/**
	 * Initializes compression.
	 */
	public void initComp(){
		if(compStream) return;
		switch(header.compMethod){
			case CompressionMethod.uncompressed:
				break;
			case CompressionMethod.zstandard, CompressionMethod.zstandardWDict:
				compStream = ZSTD_createCStream();
				readBuf.length = readBufferSize;
				ZSTD_CCtx_reset(cast(ZSTD_CStream*)compStream, ZSTD_ResetDirective.ZSTD_reset_session_only);
				ZSTD_CCtx_setParameter(cast(ZSTD_CStream*)compStream, ZSTD_cParameter.ZSTD_c_compressionLevel, header.compLevel);
				if (header.compMethod == CompressionMethod.zstandardWDict) {
					size_t errCode = ZSTD_CCtx_loadDictionary(cast(ZSTD_CStream*)compStream, dictionary.ptr, dictionary.length);
					if (ZSTD_isError(errCode)) {
						throw new CompressionException(cast(string)(fromStringz(ZSTD_getErrorName(errCode))));
					}
				}
				inBuff = ZSTD_inBuffer(readBuf.ptr, readBuf.length, 0);
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
	public void initDecomp(){
		if(compStream) return;
		switch(header.compMethod){
			case CompressionMethod.uncompressed:
				break;
			case CompressionMethod.zstandard, CompressionMethod.zstandardWDict:
				compStream = ZSTD_createDStream();
				ZSTD_initDStream(cast(ZSTD_DStream*)compStream);
				readBuf.length = readBufferSize;
				inBuff = ZSTD_inBuffer(readBuf.ptr, readBuf.length, 0);
				if (header.compMethod == CompressionMethod.zstandardWDict){
					size_t errCode = ZSTD_DCtx_loadDictionary(cast(ZSTD_DCtx*)compStream, dictionary.ptr, dictionary.length);
					if (ZSTD_isError(errCode)) {
						throw new CompressionException(cast(string)(fromStringz(ZSTD_getErrorName(errCode))));
					}
				}
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
	public Index getIndex(uint i) {
		if (i < indexes.length) return indexes[i];
		else return Index.init;
	}
	/**
	 * Returns the index of next file.
	 */
	public Index getNextIndex() {
		if (nextIndex < indexes.length) return indexes[nextIndex];
		else return Index.init;
	}
	/**
	 * Sets the index to a given point if the Datapak is random accessible.
	 */
	public Index setIndex(uint i) {
		if (this.randomAccess) {
			if (i < indexes.length) {
				nextIndex = i;
				return indexes[i];
			} else {
				return Index.init;
			}
		} else throw new UnsupportedAccessModeException("Random access is not supported with this ");
	}
	/**
	 * Returns the next file as a VFile.
	 */
	public VFile getNextAsVFile(){
		VFile result = VFile(getNextAsArray(), "");
		return result;
	}
	/**
	 * Returns the next file as an ubyte[] array.
	 */
	public ubyte[] getNextAsArray(){
		if(nextIndex >= indexes.length)
		return [];
		
		ubyte[] result = decompressFromFile(cast(size_t)(indexes[nextIndex].uncompSize));
		

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
			case ChecksumType.crc32:
				return _checkFile(CRC32());
			case ChecksumType.crc64ISO:
				return _checkFile(CRC64ISO());
			case ChecksumType.crc64ECMA:
				return _checkFile(CRC64ECMA());
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
		chkSmCalc.put(reinterpretCast!ubyte(SIGNATURE.dup));
		file.rawWrite([header]);
		chkSmCalc.put(reinterpretAsArray!ubyte(header));
		
		
		foreach (extension ; extField) {
			if (extension.length) {
				file.rawWrite(extension);
				chkSmCalc.put(extension);
			}
		}
		foreach (n, i; indexes) {
			file.rawWrite([i]);
			chkSmCalc.put(reinterpretAsArray!ubyte(i));
			if(indexExtFields.get(cast(uint)n, null) !is null){
				foreach (extension ; indexExtFields[cast(uint)n]) {
					if (extension.length) {
						file.rawWrite(extension);
						chkSmCalc.put(extension);
					}
				}
				//chkSmCalc.put(indexExtFields[cast(uint)n]);
			}
		}
		const ubyte[4] checksum = chkSmCalc.finish;
		file.rawWrite(checksum);
		
		//write each files in order of access
		foreach(size_t n, Index i; indexes){
			this.compress(paths[n], i);
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
			case CompressionMethod.zstandardWDict:
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

public ubyte[] createExtension(T)(T header, ubyte[] data) {
	return reinterpretAsArray!ubyte(header) ~ data;
}

unittest {
	DataPak.Index index;
	index.filename = "something";
	assert(index.filename == "something", index.filename);
	index.checksum!4 = [2,7,4,7];
	assert(index.checksum!4 == [2,7,4,7]);
	index.checksum!8 = [1,2,3,4,5,6,7,8];
	assert(index.checksum!8 == [1,2,3,4,5,6,7,8]);
}
unittest {
	DataPak dpkOut = new DataPak(DataPak.CompressionMethod.deflate, "test.dpk");
	dpkOut.addFile("./libzstd.dll", "libzstd.a");
	dpkOut.addFile("./zstd.exe", "zstd.a");
	dpkOut.addFile("./LICENSE", "LICENSE.a");

	dpkOut.finalize();

	DataPak dpkIn = new DataPak("test.dpk");
	//dpkIn.getNextAsArray();
}