module datapak;

public import vfile;
import bindbc.zstandard;
import etc.c.zlib;
import std.digest;
import std.bitmanip;

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
		deflate				=	"ZLIB    ",			///Last character can specify compression strength (0-9)
		zstandard			=	"ZSTD    ",			///Last two characters can specify compression stength (00-20)
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
			uint, "",				24,	///Reserved for future use
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
	protected Index[] indexes;
}