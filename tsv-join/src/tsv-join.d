/**
Command line tool that joins tab-separated value files based on a common key. 

This tool joins lines from tab-delimited files based on a common key. One file, the 'filter'
file, contains the records (lines) being matched. The other input files are searched for
matching records. Matching records are written to standard output, along with any designated
fields from the 'filter' file. In database parlance this is a 'hash semi-join'.

Copyright (c) 2015-2016, eBay Software Foundation
Initially written by Jon Degenhardt

License: Boost Licence 1.0 (http://boost.org/LICENSE_1_0.txt) 
*/
module tsv_join;

import std.stdio;
import std.format : format;
import std.typecons : tuple;

auto helpTextBrief = q"EOS
Synopsis: tsv-join --filter-file file [options] file [file...]
Options:
EOS";

auto helpText = q"EOS
Synopsis: tsv-join --filter-file file [options] file [file...]

tsv-join matches input lines against lines from a 'filter' file. The match is
based on exact match comparison of one or more 'key' fields. Fields are TAB
delimited by default. Matching lines are written to standard output, along with
any additional fields from the key file that have been specified. An example:

  tsv-join --filter-file filter.tsv --key-fields 1 --append-fields 5,6 data.tsv

This reads filter.tsv, creating a hash table keyed on field 1. Lines from data.tsv
are read one at a time. If field 1 is found in the hash table, the line is written
to standard output with fields 5 and 6 from the filter file appended. In database
parlance this is a "hash semi join". Note the asymmetric relationship: Records in
the filter file should be unique, but data.tsv lines can repeat.

tsv-join can also work as a simple filter, this is the default behavior. Example:

  tsv-join --filter-file filter.tsv data.tsv

This outputs all lines from data.tsv found in filter.tsv. --key-fields can still
be used to define the match key. The --exclude option can be used to exclude
matched lines rather than keep them.

Options:
EOS";

/** Container for command line options.
 */
struct TsvJoinOptions {
    string filterFile;               // --filter
    size_t[] keyFields;              // --key-fields
    size_t[] dataFields;             // --data-fields
    size_t[] appendFields;           // --append-fields
    bool hasHeader = false;          // --header
    string appendHeaderPrefix = "";  // --append-header-prefix
    bool writeAll = false;           // --write-all
    string writeAllValue;            // --write-all
    bool exclude = false;            // --exclude
    char delim = '\t';               // --delimiter
    bool helpBrief = false;          // --help-brief
    bool allowDupliateKeys = false;  // --allow-duplicate-keys
    bool keyIsFullLine = false;      // Derived: --key-fields 0
    bool dataIsFullLine = false;     // Derived: --data-fields 0
    bool appendFullLine = false;     // Derived: --append-fields 0

    /* Returns a tuple. First value is true if command line arguments were successfully
     * processed and execution should continue, or false if an error occurred or the user
     * asked for help. If false, the second value is the appropriate exit code (0 or 1).
     *
     * Returning true (execution continues) means args have been validated and derived
     * values calculated. In addition, field indices have been converted to zero-based.
     * If the whole line is the key, the individual fields lists will be cleared.
     */ 
    auto processArgs (ref string[] cmdArgs) {
        import std.algorithm : any, each;
        import std.getopt;

        /* Handler for --write-all. Special handler so two values can be set. */
        void writeAllHandler(string option, string value) {
            debug stderr.writeln("[writeAllHandler] |", option, "|  |", value, "|");
            writeAll = true;
            writeAllValue = value;
        }
        
        try {
            arraySep = ",";    // Use comma to separate values in command line options
            auto r = getopt(
                cmdArgs,
                "help-brief",      "          Print brief help.", &helpBrief,
                "f|filter-file",   "FILE      (Required) File with records to use as a filter.", &filterFile,
                "k|key-fields",    "n[,n...]  Fields to use as join key. Default: 0 (entire line).", &keyFields,
                "d|data-fields",   "n[,n...]  Data record fields to use as join key, if different than --key-fields.", &dataFields,
                "a|append-fields", "n[,n...]  Filter fields to append to matched records.", &appendFields,
                "header",          "          Treat the first line of each file as a header.", &hasHeader,
                "p|prefix",        "STR       String to use as a prefix for --append-fields when writing a header line.", &appendHeaderPrefix,
                "w|write-all",     "STR       Output all data records. STR is the --append-fields value when writing unmatched records.", &writeAllHandler,
                "e|exclude",       "          Exclude matching records.", &exclude,
                "d|delimiter",     "CHR       Field delimiter. Default: TAB. (Single byte UTF-8 characters only.)", &delim,
                "z|allow-duplicate-keys",
                                   "          Allow duplicate keys with different append values (last entry wins).", &allowDupliateKeys, 
                );

            if (r.helpWanted) {
                defaultGetoptPrinter(helpText, r.options);
                return tuple(false, 0);
            } else if (helpBrief) {
                defaultGetoptPrinter(helpTextBrief, r.options);
                return tuple(false, 0);
            }

            consistencyValidations(cmdArgs);
            derivations();
        } catch (Exception exc) {
            stderr.writeln("Error processing command line arguments: ", exc.msg);
            return tuple(false, 1);
        }
        return tuple(true, 0);
    }

    /* This routine does validations not handled by getopt, usually because they
     * involve interactions between multiple parameters.
     */
    private void consistencyValidations(ref string[] processedCmdArgs) {
        import std.algorithm : any;

        if (filterFile.length == 0)
            throw new Exception("Required option --filter-file was not supplied.");
        else if (filterFile == "-" && processedCmdArgs.length == 1)
            throw new Exception("A data file is required when standard input is used for the filter file (--f|filter-file -).");

        if (writeAll && appendFields.length == 0)
            throw new Exception("Use --a|append-fields when using --w|write-all.");

        if (writeAll && appendFields.length == 1 && appendFields[0] == 0)
            throw new Exception("Cannot use '--a|append-fields 0' (whole line) when using --w|write-all.");

        if (appendFields.length > 0 && exclude)
            throw new Exception("--e|exclude cannot be used with --a|append-fields.");

        if (appendHeaderPrefix.length > 0 && !hasHeader)
            throw new Exception("Use --header when using --p|prefix.");

        if (dataFields.length > 0 && keyFields.length != dataFields.length)
            throw new Exception("Different number of --k|key-fields and --d|data-fields.");

        if (keyFields.length == 1 && dataFields.length == 1 &&
            ((keyFields[0] == 0 && dataFields[0] != 0) || (keyFields[0] != 0 && dataFields[0] == 0)))
        {
            throw new Exception("If either --k|key-field or --d|data-field is zero both must be zero.");
        }

        if ((keyFields.length > 1    && any!(a => a == 0)(keyFields)) ||
            (dataFields.length > 1   && any!(a => a == 0)(dataFields)) ||
            (appendFields.length > 1 && any!(a => a == 0)(appendFields)))
        {
            throw new Exception("Field 0 (whole line) cannot be combined with individual fields (non-zero).");
        }

    }

    /* Post-processing derivations. */
    void derivations() {
        import std.algorithm : each;
        import std.range; 

        // Convert 'full-line' field indexes (index zero) to boolean flags.
        if (keyFields.length == 0) {
            assert(dataFields.length == 0);
            keyIsFullLine = true;
            dataIsFullLine = true;
        }
        else if (keyFields.length == 1 && keyFields[0] == 0) {
            keyIsFullLine = true;
            keyFields.popFront;
            dataIsFullLine = true;
            
            if (dataFields.length == 1) {
                assert(dataFields[0] == 0);
                dataFields.popFront;
            }
        }

        if (appendFields.length == 1 && appendFields[0] == 0) {
            appendFullLine = true;
            appendFields.popFront; 
        }

        assert(!(keyIsFullLine && keyFields.length > 0));
        assert(!(dataIsFullLine && dataFields.length > 0));
        assert(!(appendFullLine && appendFields.length > 0));
        
        // Switch to zero-based field indexes.
        keyFields.each!((ref a) => --a);
        dataFields.each!((ref a) => --a);
        appendFields.each!((ref a) => --a);
    }
}

/** 
Main program.
 */
int main(string[] cmdArgs) {
    TsvJoinOptions cmdopt;
        auto r = cmdopt.processArgs(cmdArgs);
    if (!r[0]) {
        return r[1];
    }
    try {
        tsvJoin(cmdopt, cmdArgs[1..$]);
    }
    catch (Exception exc) {
        stderr.writeln("Error: ", exc.msg);
        return 1;
    }

    return 0;
}

/** tsvJoin does the primary work of the tsv-join program.
 */
void tsvJoin(in TsvJoinOptions cmdopt, in string[] inputFiles) {
    import tsvutil : InputFieldReordering;
    import std.algorithm : splitter;
    import std.array : join;
    import std.range;
    import std.conv; 

    /* State, variables, and convenience derivations.
     *
     * Combinations of individual fields and whole line (field zero) are convenient for the
     * user, but create complexities for the program. Many combinations are disallowed by
     * command line processing, but the remaining combos still leave several states. Also,
     * this code optimizes by doing only necessary operations, further complicating state
     * Here's a guide to variables and state.
     * - cmdopt.keyFields, cmdopt.dataFields arrays - Individual field indexes used as keys.
     *      Empty if the  whole line is used as a key. Must be the same length.
     * - cmdopt.keyIsFullLine, cmdopt.dataIsFullLine - True when the whole line is used key.
     * - cmdopt.appendFields array - Indexes of individual filter file fields being appended.
     *      Empty if appending the full line, or if not appending anything.
     * - cmdopt.appendFullLine - True when the whole line is being appended.
     * - isAppending - True is something is being appended.
     * - cmdopt.writeAll - True if all lines are being written
     */
    /* Convenience derivations. */
    auto numKeyFields = cmdopt.keyFields.length;
    auto numAppendFields = cmdopt.appendFields.length;
    bool isAppending = (cmdopt.appendFullLine || numAppendFields > 0);

    /* Mappings from field indexes in the input lines to collection arrays. */
    auto filterKeysReordering = new InputFieldReordering!char(cmdopt.keyFields);
    auto dataKeysReordering = (cmdopt.dataFields.length == 0) ?
        filterKeysReordering : new InputFieldReordering!char(cmdopt.dataFields);
    auto appendFieldsReordering = new InputFieldReordering!char(cmdopt.appendFields);

    /* The master filter hash. The key is the delimited fields concatenated together
     * (including separators). The value is the appendFields concatenated together, as
     * they will be appended to the input line. Both the keys and append fields are
     * assembled in the order specified, though this only required for append fields.
     */
    string[string] filterHash;
    string appendFieldsHeader;

    /* The append values for unmatched records. */
    char[] appendFieldsUnmatchedValue;

    if (cmdopt.writeAll) {
        assert(cmdopt.appendFields.length > 0);  // Checked in consistencyValidations

        // reserve space for n values and n-1 delimiters
        appendFieldsUnmatchedValue.reserve(cmdopt.appendFields.length * (cmdopt.writeAllValue.length + 1) - 1);

        appendFieldsUnmatchedValue ~= cmdopt.writeAllValue; 
        for (size_t i = 1; i < cmdopt.appendFields.length; ++i) {
            appendFieldsUnmatchedValue ~= cmdopt.delim;
            appendFieldsUnmatchedValue ~= cmdopt.writeAllValue;
        }
    }

    /* Read the filter file. */
    {
        bool needPerFieldProcessing = (numKeyFields > 0) || (numAppendFields > 0);
        auto filterStream = (cmdopt.filterFile == "-") ? stdin : cmdopt.filterFile.File;
        foreach (lineNum, line; filterStream.byLine.enumerate(1)) {
            debug writeln("[filter line] |", line, "|");
            if (needPerFieldProcessing) {
                filterKeysReordering.initNewLine;
                appendFieldsReordering.initNewLine;
                
                foreach (fieldIndex, fieldValue; line.splitter(cmdopt.delim).enumerate) {
                    filterKeysReordering.processNextField(fieldIndex,fieldValue);
                    appendFieldsReordering.processNextField(fieldIndex,fieldValue);
                    
                    if (filterKeysReordering.allFieldsFilled && appendFieldsReordering.allFieldsFilled) {
                        break;
                    }
                }
                // Processed all fields in the line.
                if (!filterKeysReordering.allFieldsFilled || !appendFieldsReordering.allFieldsFilled) {
                    throw new Exception(
                        format("Not enough fields in line. File: %s, Line: %s",
                               (cmdopt.filterFile == "-") ? "Standard Input" : cmdopt.filterFile, lineNum));
                }
            }

            string key = cmdopt.keyIsFullLine ?
                line.to!string : filterKeysReordering.outputFields.join(cmdopt.delim).to!string; 
            string appendValues = cmdopt.appendFullLine ?
                line.to!string : appendFieldsReordering.outputFields.join(cmdopt.delim).to!string;
            
            debug writeln("  --> [key]:[append] => [", key, "]:[", appendValues, "]"); 

            if (lineNum == 1 && cmdopt.hasHeader) {
                if (cmdopt.appendHeaderPrefix.length == 0) {
                    appendFieldsHeader = appendValues;
                } else {
                    foreach (fieldIndex, fieldValue; appendValues.splitter(cmdopt.delim).enumerate) {
                        if (fieldIndex > 0) {
                            appendFieldsHeader ~= cmdopt.delim;
                        }
                        appendFieldsHeader ~= cmdopt.appendHeaderPrefix;
                        appendFieldsHeader ~= fieldValue;
                    }
                }
            }
            else {
                if (isAppending && !cmdopt.allowDupliateKeys) {
                    string* currAppendValues = (key in filterHash);
                    if (currAppendValues !is null && *currAppendValues != appendValues) {
                        throw new Exception(
                            format("Duplicate keys with different append values (use --z|allow-duplicate-keys to ignore)\n   [key 1][values]: [%s][%s]\n   [key 2][values]: [%s][%s]",
                                   key, *currAppendValues, key, appendValues));
                    }
                }
                filterHash[key] = appendValues;
            }
        }
    }

    filterHash.rehash;    // For faster lookups. (Per docs. In my tests no performance delta.)

    /* Now process each input file, one line at a time. */

    bool headerWritten = false;
    foreach (filename; (inputFiles.length > 0) ? inputFiles : ["-"]) {
        auto inputStream = (filename == "-") ? stdin : filename.File();
        foreach (lineNum, line; inputStream.byLine.enumerate(1)) {
            debug writeln("[input line] |", line, "|"); 
            if (cmdopt.hasHeader && lineNum == 1) {
                /* Header line processing. */
                if (!headerWritten) {
                    write(line);
                    if (isAppending) {
                        write(cmdopt.delim, appendFieldsHeader);
                    }
                    writeln();
                    headerWritten = true;
                }
            }
            else {
                /* Regular line (not a header line). 
                 * 
                 * Next block checks if the input line matches a hash entry. Two cases:
                 *   a) The whole line is the key. Simply look it up in the hash.
                 *   b) Individual fields are used as the key - Assemble key and look it up.
                 *
                 * At the end of the appendFields will contain the result of hash lookup.
                 */
                string* appendFields;
                if (cmdopt.keyIsFullLine) {
                    appendFields = (line in filterHash);
                }
                else {
                    dataKeysReordering.initNewLine;
                    foreach (fieldIndex, fieldValue; line.splitter(cmdopt.delim).enumerate) {
                        dataKeysReordering.processNextField(fieldIndex, fieldValue);

                        if (dataKeysReordering.allFieldsFilled) {
                            break;
                        }
                    }
                    // Processed all fields in the line.
                    if (!dataKeysReordering.allFieldsFilled) {
                        throw new Exception(
                            format("Not enough fields in line. File: %s, Line: %s",
                                   (filename == "-") ? "Standard Input" : filename, lineNum));
                    }
                    appendFields = (dataKeysReordering.outputFields.join(cmdopt.delim) in filterHash); 
                }

                bool matched = (appendFields !is null);
                debug writeln("   --> matched? ", matched); 
                if (cmdopt.writeAll || (matched && !cmdopt.exclude) || (!matched && cmdopt.exclude)) {
                    write(line);
                    if (isAppending) {
                        write(cmdopt.delim, matched ? *appendFields : appendFieldsUnmatchedValue);
                    }
                    writeln();
                }
            }
        }
    }
}
