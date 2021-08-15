module datapak.extensions;

/**
 * Default extension for adding general support for using it as a regular file archival tool.
 * This does not contain user-privilege settings, those will be relegated to another struct. 
 */
struct OSExt {
align(1):
	char[6]		id = "OSExt ";			///Identifies that this field is a DataPak_OSExt struct
	ushort		size = OSExt.sizeof;	///Size of this field
	char[200]	nameExt;				///Stores filename extension + relative path
	ulong		creationDate;			///Creation date in 64 bit POSIX time format
	ulong		modifyDate;				///Modification date in 64 bit POSIX time format
	uint		fieldA;					///Flag bank A, stores file attributes
    uint        fieldB;                 ///Flag bank B, reserved for future use
	///Sets the name extension of the file
	public string name(string val) @safe @property @nogc nothrow pure{
		for (size_t i ; i < nameExt.length ; i++)
			nameExt[i] = 0xFF;
		foreach (i , c ; val)
			nameExt[i] = c;
		return val;
	}
	///Gets the name extension of the file
	public string name() @safe @property nothrow pure const {
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
 * Extension to store OS privileges for POSIX systems.
 */
struct OSExtP {
align(1):
	char[6]		id = "OSExtP";			///Identifies that this field is a DataPak_OSExtP struct
	ushort		size = OSExtP.sizeof;	///Size of this field
	uint		userID;
	uint		groupID;
	char[32]	userName;
	char[32]	groupName;
	uint		field;					///Access control flags, etc. 
}
/**
 * Stores flags related to access control.
 */
enum AccessControlFlags {
	OutExec				=	0x001,
	OutWrite			=	0x002,
	OutRead				=	0x004,
	GroupExec			=	0x008,
	GroupWrite			=	0x010,
	GroupRead			=	0x020,
	OwnerExec			=	0x040,
	OwnerWrite			=	0x080,
	OwnerRead			=	0x100,
}