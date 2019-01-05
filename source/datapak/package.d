module datapak;

public import vfile;
import bindbc.zstandard;
import etc.c.zlib;
import std.digest;
import std.digest.murmurhash;
import std.bitmanip;
import std.stdio;

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
 * data to save some space, but only if the index field is also compressed.</li>
 * <li>Array of DataPak indexes. Each entry can have some extension. Can be compressed alongside with the main data to save some space.</li>
 * <li>Data</li>
 * </ul>
 */
public class DataPak{
	static enum char[8] SIGNATURE = "DataPak.";		///Every DataPak file begins with this.
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
	 * Selects between checksums
	 */
	public enum DataPakChecksumType : ubyte{
		none				=	0,
		ripeMD				=	1,
		murmurhash32_32		=	2,
		murmurhash128_32	=	3,
		murmurhash128_64	=	4,
		md5					=	10,
		crc32				=	11,///Note: the default one from std.digest is used, which gives a different output from other methods!
		crc64				=	12,///ISO only!
	}
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
		ubyte[4]	checksum;		///Murmurhash32/32 checksum for the header, extension field, and indexes. When processing, this field should set to all zeroes.
	}
	/**
	 * Index representing data for a file.
	 */
	public struct Index{
	align(1):
		ulong 		offset;			///Points to where the file begins in the stream
		ushort		extFieldSize;	///Extension area size for the index
		ushort		sizeH;			///The upper 16 bits of the file's size
		uint		sizeL;			///The lower 32 bits of the file's size
		char[96]	filename;		///Name of the file
		ubyte[16]	checksum;		///Per file checksum
	}
	protected Header header;
	protected File file;
	protected Index[] indexes;
	protected ubyte[] extField;
	protected ubyte[][uint] indexExtFields;
	protected bool readOnly;
	/**
	 * Loads a DataPak file from disk for reading.
	 */
	public this(string filename){
		this(File(filename));
		readOnly = true;
	}
	///Ditto, but also can specify writing.
	public this(ref File f){
		ubyte[] readBuf;
		MurmurHash3!(32, 32) chkSmCalc = MurmurHash3!(32, 32)(0x2E_68_50_4B);
		readBuf.length = Header.sizeof;
		f.rawRead(readBuf);
		header = *(cast(Header*)(cast(void*)readBuf.ptr));
		//ubyte[4] chkSm = header.checksum;
		//header.checksum = [0x0, 0x0, 0x0, 0x0];
		readBuf.length -= 4;
		readBuf.length += 4;
		file = f;
		chkSmCalc.putElements(cast(uint[])(cast(void[])readBuf));
		if(header.extFieldSize){
			if(!header.compExtField){
				extField.length = header.extFieldSize;
				f.rawRead(extField);
			}else{

			}
			chkSmCalc.putElements(cast(uint[])(cast(void[])extField));
		}
		if(!header.compIndex){
			indexes.length = header.numOfIndexes;
			readBuf.length = Index.sizeof;
			for(int i; i < indexes.length; i++){
				f.rawRead(readBuf);
				indexes[i] = *(cast(Index*)(cast(void*)readBuf.ptr));
				chkSmCalc.putElements(cast(uint[])(cast(void[])readBuf));
				if(indexes[i].extFieldSize){
					readBuf.length = indexes[i].extFieldSize;
					f.rawRead(readBuf);
					indexExtFields[i] = readBuf.dup;
					chkSmCalc.putElements(cast(uint[])(cast(void[])readBuf));
					readBuf.length = Index.sizeof;
				}
			}
		}else{

		}
		const ubyte[4] checksum = chkSmCalc.finish();
		if(header.checksum != checksum){
			throw new BadChecksumException("Murmurhash3-32/32 error");
		}
		
	}
	/**
	 * Decompresses a given amount from the file
	 */
	protected ubyte[] decompressFromFile(size_t amount){
		switch(header.compMethod){
			default:
				throw new Exception("Unknown compression method");
		}
	}
}

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