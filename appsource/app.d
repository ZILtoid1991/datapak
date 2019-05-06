import std.stdio;
import std.conv : to;

import datapak;
import darg;

struct Options{
	@Option("help", "h")
	@Help("Prints this help.")
	OptionFlag help;

	@Option("pack", "p")
	@Help("Creates a new *.dpk file.")
	string output;

	@Argument("files", Multiplicity.zeroOrMore)
	@Help("Specifies the input files. If not present, then the software will ask for them after it's initialized for 
			packing files. If set on unpacking, then it'll specify the files that the user wants to unpack.")
	string[] files;

	@Option("compMethod", "c")
	@Help("Specifies the compression method when creating a new *.dpk file. Default is none. Currently supported
			values are: none, deflate, zstd")
	string compMethod = "none";

	@Option("compLevel", "l")
	@Help("Specifies the compression level. Can be `fastest`, `default`, `max`, or a number within the range of the algorithm.")
	string compLevel = "default";

	@Option("hash", "h")
	@Help("Specifies the hash or checksum for the files. Default is none.")
	string hashMethod = "none";

	@Option("osext")
	@Help("Adds osext fields for each file during compression.")
	OptionFlag osext;

	@Option("unpack", "u")
	@Help("Unpacks a valid *.dpk file.")
	string input;
}

immutable string help = helpString!Options();
immutable string usage = usageString!Options("");

int main (string[] args) {
	Options options;
	writeln("Datapak archiver. \nby Laszlo Szeremi");
	try {
		options = parseArgs!Options(args[1..$]);
	} catch (ArgParseError e) {
        writeln(e.msg);
        writeln(usage);
        return 1;
    } catch (ArgParseHelp e) {
        // Help was requested
        writeln(usage);
        write(help);
        return 0;
    }

	if (options.input) {
		try {
			DataPak dpk = new DataPak(options.input);
			//dpk.openDataStreamForReading();
			DataPak.Index i = dpk.getNextIndex();
			while (i.filename.length) {
				writeln("Decompressing ", i.filename);
				File output = File (i.filename, "wb");
				output.rawWrite(dpk.getNextAsArray);
				i = dpk.getNextIndex();
			}
			writeln("Done!");
		} catch (Exception e) {
			writeln(e.msg);
		}
	} else if (options.output) {
		if (!options.files.length){
			string input;
			writeln("Please specify the files to be added one-by-one. Press enter at an empty line if finished.");
			do {
				writeln("Enter filename:");
				input = readln!string();
				options.files ~= input[0..$-1];
			} while (input != "\n");
			options.files.length--;
			if(options.files.length == 0){
				writeln("No files were specified.");
				return 1;
			}
		}
		DataPak.Header header;
		switch (options.compMethod) {
			case "none":
				header.compMethod = DataPak.CompressionMethod.uncompressed;
				break;
			case "zstd":
				header.compMethod = DataPak.CompressionMethod.zstandard;
				switch (options.compLevel) {
					case "fastest":
						header.compLevel = 1; 
						break;
					case "default":
						header.compLevel = 10; 
						break;
					case "max":
						header.compLevel = 22; 
						break;
					default:
						header.compLevel = to!ubyte(options.compLevel);
						break;
				}
				break;
			case "deflate":
				header.compMethod = DataPak.CompressionMethod.deflate;
				switch (options.compLevel) {
					case "fastest":
						header.compLevel = 1; 
						break;
					case "default":
						header.compLevel = 6; 
						break;
					case "max":
						header.compLevel = 9; 
						break;
					default:
						header.compLevel = to!ubyte(options.compLevel);
						break;
				}
				break;
			default:
				writeln("Unknown compression method.");
				return 1;
		}
		header.numOfIndexes = cast(uint)options.files.length;
		DataPak dpk = new DataPak(header, options.output);
		foreach(f ; options.files){
			writeln("Indexing ", f);
			dpk.addFile(f);
		}
		writeln("Compressing files");
		dpk.finalize;
		writeln("Done!");
	} else {
		writeln(usage);
        write(help);
	}
	return 0;
}
