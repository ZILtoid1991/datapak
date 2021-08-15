import std.stdio;
import std.conv : to;

import datapak;
import darg;
import scone;


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

	@Option("indivComp", "i")
	@Help("Specifies the use of a dictionary and individual compression for algorithms supporting it.")
	OptionFlag indivComp;

	@Option("hash", "s")
	@Help("Specifies the hash or checksum for the files. Default is none.")
	string hashMethod = "none";

	@Option("osext")
	@Help("Adds osext fields for each file during compression.")
	OptionFlag osext;

	@Option("unpack", "u")
	@Help("Unpacks a valid *.dpk file.")
	string input;

	@Option("destination", "d")
	@Help("Specifies the destination folder for decompression.")
	string dest;
}

immutable string help = helpString!Options();
immutable string usage = usageString!Options("");

int main (string[] args) {
	DataPak.loadZSTD;
	Options options;
	if (arg.length > 1) {
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
			if(options.dest.length){
				if(!(options.dest[$-1] == '/' || options.dest[$-1] == '\\'))
					options.dest ~= '/';
			}
			try {
				DataPak dpk = new DataPak(options.input);
				//dpk.openDataStreamForReading();
				DataPak.Index i = dpk.getNextIndex();
				while (i.filename.length) {
					writeln("Decompressing ", i.filename);
					File output = File (options.dest ~ i.filename, "wb");
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
			switch (options.hashMethod){
				case "none":
					break;
				case "crc32":
					header.checksumType = DataPak.ChecksumType.crc32;
					break;
				case "crc64ISO":
					header.checksumType = DataPak.ChecksumType.crc64ISO;
					break;
				case "crc64ECMA":
					header.checksumType = DataPak.ChecksumType.crc64ECMA;
					break;
				default:
					writeln("Unknown hash/checksum method.");
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
	} else {
		window.title("Datapak creator tool");
		window.resize(80,25);//Request standard console size
		uint mode = 1;
		while (mode) {
			window.clear();
			window.write(0,0,Color.red.foreground,
				"Datapak creator and unpacker, V0.1.0 - Creator mode");
			switch (mode){
				default:
					window.write(0,1,Color.black.foreground, Color.white.background,
						"Press \"esc\" to quit the application, \"enter\" to create new Datapak file," );
					window.write(0,2,Color.black.foreground, Color.white.background,
						"or \"o\" to open a preexiting file for viewing and unpacking.");
					break;
			}
		}
		return 0;
	}
}
