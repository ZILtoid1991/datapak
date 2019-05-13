# Datapak File specifications

*NOTE:* All size specifications for fields follow the Intel naming conventions. All datafields are little endian unless noted otherwise.

## Signature

* All datapak file by standard start with the "DataPak." string.
* Non-standard files can use different signatures, eg. if they contain special extensions mandatory for a certain usecase, or for future revisions which might use the reserved part of the header's bitfield. Must be 8 bytes long.
* Computed into the checksum.

## Header

The header specifies most properties of the file. Equiped to handle most scenarios that could be present in a 64bit environment, such as files larger than 4 GB. Must be computed into the checksum.

Outline consists of:
* indexSize: QWORD, unsigned. Describes the size of the index field in bytes, including extensions for individual headers.
* decompSize: QWORD, unsigned. Describes the decompressed size of the file.
* compMethod: string, 8 bytes long. Describes the compression method for the file. Currently standardized strings are: "UNCMPRSD", "ZLIB    ", "ZSTD    ", "LZ4     ".
* extFieldSize: DWORD, unsigned. Describes the uncompressed size of the extended field in bytes. If zero, the extension field is not present in the file.
* numOfIndexes: DWORD, unsigned. Equals with the number of file indexes stored in the index field.
* bitfield: DWORD, unsigned. Stores various options that can be depicted on less than 8 bits.

###### Bitfield specs:

* compIndex: 1 bit. If true, then the index field is compressed with the same method as the data.
* compExtField: 1 bit. If true, then the header extension field is compressed with the same method as the data.
* checksumType: 6 bit. Specifies what kind of checksum/hash do the indexes contain. As of May of 2019, values 0-14 are used, 15-31 are restricted to future use, 32-63 are for custom implementations.
* compLevel: 6 bit. Specifies the level of compression.
* reserved: 18 bit. Should be set to zero as of now, later revisions might use it for other purposes (describing encryption types?).

### Extension field

Computed into the checksum. Can be compressed if needed and possible. Applications include: encryption type indication, metadata, compression dictionaries...

General outline of an extension header should look like:
* signature: 8 bytes of string or magic number.
* fieldSize: DWORD, unsigned. Describes the field size in bytes, including signature and this field.

Extensions can be as short as just the header, such application might be enough to indicate encryption type.

## Indexes

Computed into the checksum. Can be compressed. Are in the same order as the files themselves. Indexes describe file position, size, name, also store individual checksums or hashes.

The Index struct consists of:
* offset: QWORD, unsigned. Specifies the position where the file begins in the decompressed stream.
* extFieldSize: WORD, unsigned. Specifies if there's any extension for this index (greater than zero), and its size in bytes.
* sizeH: WORD, unsigned. Contains bits 32-47 of the file's decompressed size.
* sizeL: DWORD, unsigned. Contains bits 31-0 of the file's decompressed size.
* field: string, 112 bytes. Contains the filename in the front, terminated with 0xFF, also contains the hash/checksum in the end as binary. Note that very-long hash-codes or checksums severely limiy the lenght of the filename, unless extensions are used. At least one 0xFF character must be between the hash/checksum field and the filename.

Max size of a file can be 2^48 - 1 bytes, or almost 262_144 gigabytes. If this ever becomes too small, chaining could be enabled.

### Index extensions

Must be described to each index individually. Applications include: metadata, filename extensions, OS related stuff like dates, privileges, etc...

General outline af an index extension header should look like:
* signature: 6 bytes of string or magic number.
* fieldSize: WORD, unsigned. Describes the field size in bytes, including signature and this field.

Similarly to header extensions, it can also be as small as just the extension header.

## CRC32 header checksum

Usually put at the end of the index fields, but always at the end of the uncompressed field, and always after the header.

# Version history

### Version one with no revisions

* Initial publication of the format.
* Standard extensions are not yet finalized.