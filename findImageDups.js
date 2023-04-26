// To see options:
// node findImageDups.js -h
//
// Tools to use exif data to find duplicate images
const exifFields = ["DateTimeOriginal","GPSTimeStamp","GPSImgDirection","BrightnessValue","HasExtendedXMP","ShutterSpeedValue","ExposureTime","SubSecTime",
                    "SubSecTimeDigitized","ISO","SubSecTimeOriginal", "Description", "ModifyDate","UserComment", "Subject", "Software", "ImageSize"];
const omitFields = ["FileInodeChangeDate","FileModifyDate","FileAccessDate", "SourceFile", "Directory", "filepath", "FileName", "FilePermissions", "MediaDataOffset"];

const fs = require("fs");
const exifr = require('exifr');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('node:child_process');

let dupCount = 0;

const arrayOpts = ['skip', 'load', 'deletematch', 'dir','videodir'];
const getOptions = (args) => {
    const options = {}; 
    let opt = '';
    for (let i=2;i<args.length;i++) {
        // -opts are boolean
        if (args[i].startsWith('-')) {
            opt = args[i].replace(/^-/,'');
            if (arrayOpts.includes(opt)) {
                options[opt] = [];
            }
            else {
                options[opt] = true;
            }
        }
        // assume a value without a opt is the value for the previous opt item
        else if (opt) {
            if (arrayOpts.includes(opt)) {
                options[opt].push(args[i]);
            }
            else {
                options[opt] = args[i];
            }
        }
    }
    return options;
}

const LOG_LEVEL = {
    FATAL: 0,
    ERROR: 1,
    WARN:  2,
    INFO:  3,
    DEBUG: 4,
    TRACE: 5,
    ALL:   6
}

let _LOG_NAMES = [];
Object.keys(LOG_LEVEL).forEach( k => {
    _LOG_NAMES[LOG_LEVEL[k]] = k;
});

const log = (level, ...message) => {
    if (level <= verbosity) {
        console.log(_LOG_NAMES[level],...message);
        if (level <= LOG_LEVEL.WARN) {
            console.error(_LOG_NAMES[level],...message);
        }
    }
}
log.error = (...msg) => {
    log(LOG_LEVEL.ERROR,...msg);
}
log.warn = (...msg) => {
    log(LOG_LEVEL.WARN,...msg);
}
log.info = (...msg) => {
    log(LOG_LEVEL.INFO,...msg);
}
log.trace = (...msg) => {
    log(LOG_LEVEL.TRACE,...msg);
}
log.debug = (...msg) => {
    log(LOG_LEVEL.DEBUG,...msg);
}
log.fatal = (...msg) => {
    log(LOG_LEVEL.FATAL,...msg);
}

const files = {};
let byTime = {};


const showHelp = () => {

log.info(`USAGE:
    OPTIONS:
    -verbose 2               set verbosity. 0 is least verbose, 6 is most; default is 3
    -verbose DEBUG           set verbosity via log level name (ERROR, WARN, INFO, TRACE, DEBUG, FATAL)
    -file file               filename to get tags
    -dir dir...              process directory for tags
    -save file               save the metadata for files
    -load file file2...      load file of metadata
    -compare                 compare files
    -stats                   show count of photos with same date
    -exiftool                Lookup data in exiftool when comparing (slow!)
    -keepmatch string        Prefer to keep items that match string
    -deletematch string...   Prefer to delete items matching string[s]
    -only                    Only match with keepmatch string as source (requires keepmatch)
    -delete                  Delete duplicates
    -video                   Process Video Files (slow)
    -videodir dir...         Read in video directory
    -movedir root            Root of directory to move files to (will move to year directory under) (requires stats)
    -move                    Actually move files
    -skip dir...             skip directories with path
    -picasa                  remove Picasa files if original exists
    -nothumb                 Do not compare thumbnails with Picasa compare
    -undefined               Process duplicates even with undefined time
    -noyear                  Allow deleting files even if original not in correct year
    -closesize               Allow matching items that are within .1% of size
    -hash                    Compare hashes of image portion

`);
}        

    
const options = getOptions(process.argv);
let verbosity = 3;
if (options.hasOwnProperty('verbose')) {
    if (LOG_LEVEL.hasOwnProperty(options.verbose)) {
        verbosity = LOG_LEVEL[options.verbose];
    }
    else {
        verbosity = (options.hasOwnProperty('verbose') && options.verbosity !== true) ? options.verbose-0 : 3;
    }
}
log.info("VERBOSITY:",verbosity);
log.info("OPTIONS:",options);
if (!options.file && !options.dir && !options.load && !options.videodir) {
    showHelp();
    process.exit();
}
if (options.h || options.help) {
    showHelp();
    process.exit();
}
if (!options.nothumb) {
    exifFields.push('ThumbnailLength');
}
const isYearDirectoryCorrect = (file, exif) => {

    let yearTaken;

    log.trace(`Getting year info from ${file} - exif:`,exif);
    const jsonInfo = `${file}.json`;
    if (fs.existsSync(jsonInfo)) {
        log.trace(`Getting year from json file: ${file}`);
        let config;
        try {
            config = JSON.parse(fs.readFileSync(jsonInfo));
            const takenDate = config.photoTakenTime ? config.photoTakenTime.timestamp*1000 : config.createTime.timestamp * 1000;
            yearTaken = new Date(takenDate).getFullYear();
        }
        catch (e) {
            log.warn(`Error reading json for year`,e,config);
        }
    }
    if (!yearTaken && typeof exif === 'string') {
        log.trace(`String exif: ${exif}`);
        if (/\d{4}:\d\d:\d\d \d\d:\d\d:\d\d/.test(exif)) {
            yearTaken=exif.replace(/:.+$/,'');
        }
        else {
            const dateObj = new Date(exif);
            yearTaken = dateObj.getFullYear();
            if (!yearTaken || isNaN(yearTaken)) {
                log.debug(`Unable to get date from: ${exif} (${dateObj})`);
                yearTaken = null;
            }
        }
    }
    else if (exif && exif.DateTimeOriginal) {
        log.trace(`Object exif (DateTimeOriginal): ${exif.DateTimeOriginal}`);
        yearTaken=`${exif.DateTimeOriginal}`.substring(0,4);
    }
    if ((!yearTaken || yearTaken == 0) && exif && exif.MediaCreateDate) {
        log.trace(`Object exif (MediaCreateDate): ${exif.DateTimeOriginal}`);
        yearTaken = `${exif.MediaCreateDate}`.substring(0,4);
    }
    if (exif.Warning && exif.Warning.indexOf('incorrect time') !== -1 ) {
        log.trace(`exif warning: ${exif.Warning}`);
        const tmpYear = extractYearFromFileName(file);
        if (tmpYear !== yearTaken && tmpYear) {
            yearTaken = tmpYear;
            log.warn(`Using file year rather than exif due to warning: ${file} - tmpYear: ${tmpYear} - yearTaken: ${yearTaken}, warn:${exif.Warning}`);
        }
    }
    // must be == because yearTaken may be "0000", which is not caught by !yearTaken and is cast to "0"
    if (!yearTaken || yearTaken == 0) {
        log.trace(`no year taken: ${yearTaken}`);
        const dateCreated = exif?.CreationDate;
        if (dateCreated) {
            yearTaken = dateCreated.replace(/:.+$/,'');
        }
        // still don't have a yearTaken? get it from filename
        if ((!yearTaken || yearTaken == 0)) {
            yearTaken = extractYearFromFileName(file);
        }
    }
    const matches = file.match(/sortedByYear\/([^\/]+)/);
    if (!matches) {
        log.trace(`File does not appear in sortedByYear: ${file} - not correct year`);
        return {isOk: false, yearTaken:yearTaken, fileYear:null};
    }
    const year = matches[1];


    log.trace(`directory YEAR: ${year}, year taken: ${yearTaken} - file: ${file}`);
    if (year == yearTaken) {
        log.trace("correct year");
        return {isOk: true, yearTaken:yearTaken, fileYear:year};
    }
    else {
        return {isOk: false, yearTaken:yearTaken, fileYear:year};
    }
}

const callExifTool = (itemsToLookup) => {
    try {
        log.trace(`exiftool length: ${itemsToLookup}, args: ${itemsToLookup}`);
        const exifdata = execFileSync('exiftool', ['-j',...itemsToLookup], {encoding: 'utf-8'});
        log.trace("EXIFTOOL DATA:",exifdata);
        return JSON.parse(exifdata);
    }
    catch (e) {
        log.info("ERROR",e);
        return [];
    }
}

const exifHash = (file) => {
    try {
        log.trace(`Getting hash for image portion of ${file}`);
        const img = execFileSync('exiftool',[file,'-all=','-o','-'], {maxBuffer: 1024*1024*40});
        const hashsum = crypto.createHash('sha256');
        hashsum.update(img);
        const base64 = hashsum.digest('hex');
        log.trace(`filehash: \tName:\t${file}\timage size\t${img.length}\t${base64}`);
        return base64;
    }
    catch (e) {
        log.error(`Unable to get hash for ${file}`,e);
        }
    return null;
}
const filterLookupList = (files) => {

    const filesToLookup = [];
    files.forEach(file => {
        log.trace(`does ${file.filepath} exist`);
        if (fs.existsSync(file.filepath)) {
            log.trace(`yes, ${file.filepath} exists`);
            if (options.skip && options.skip.some(s => file.filepath.indexOf(s) !== -1)) {
                log.trace(`not looking up because ${file.filepath} is skipped`);
            }
            else {
                filesToLookup.push(file);
            }
        }
    });
    filesToLookup.sort((a,b) => {
        // keepmatch items bubble to front
        if (options.keepmatch) {
            let match = b.filepath.includes(options.keepmatch) - a.filepath.includes(options.keepmatch);
            if (match) {
                return match;
            }
        }
        if (options.deletematch) {
            let match = options.deletematch.some(m => a.filepath.includes(m)) - options.deletematch.some(m => b.filepath.includes(m));
            if (match) {
                return match;
            }
        }
        // parens bubble toward back
        return a.filepath.includes('(') - b.filepath.includes('(');
    })
    log.trace("files to lookup",filesToLookup);
    return filesToLookup;
}

const deleteFile = ({toDelete, src}) => {
    if (!fs.existsSync(src) ) {
        log.warn(`Not deleting ${toDelete} because SRC: ${src} does not exist`);
        return false;
    }
    if (!fs.existsSync(toDelete)) {
        log.warn(`Not deleting ${src} because DEST:${toDelete} does not exist`);
        return false;
    }
    try {
        const srcStat = fs.statSync(src);
        const deleteStat = fs.statSync(toDelete);
        const srcIsAtLeastAsBig = srcStat.size >= deleteStat.size;
        const slightlyLargerDelete = (options.deletematch && (options.deletematch.some(m => {return toDelete.indexOf(m) !== -1})) && (deleteStat.size - srcStat.size < 50));
        log.trace(`delete check: srcIsAtLeastAsBig: ${srcIsAtLeastAsBig} , slightlyLargerDelete: ${slightlyLargerDelete}`);
        if (srcIsAtLeastAsBig || slightlyLargerDelete) {
            if (options.keepmatch && toDelete.indexOf(options.keepmatch) !== -1 && src.indexOf(options.keepmatch) === -1) {
                log.info(`${toDelete} matches ${keepmatch}, while src: ${src} does not, not deleting`);
                return false;
            }

            if (options.delete) {
                fs.unlinkSync(toDelete);
                log.info(`\tDELETED\t${toDelete}\tMATCH:\t${src}\tSIZE:\t${deleteStat.size - srcStat.size}\t${deleteStat.size}\t${srcStat.size}`);
                return true;
            }
            else {
                log.info(`\twould be DELETED, but not because flag is off\t${toDelete}\tMATCH:\t${src}\tSIZE:\t${deleteStat.size - srcStat.size}\t${deleteStat.size}\t${srcStat.size}`);
                return true;
            }
        }
        else {
            log.info(`Not deleting ${toDelete} because size is larger than ${src} (${deleteStat.size} > ${srcStat.size})`);
        }
    }
    catch (e) {
        log.error(`unable to delete file ${toDelete}`,e);
    }
    return false;

}
const extractYearFromFileName = (filename) => {
    // DSCN files don't have year
    if ((filename.indexOf('/DSCN') !== -1)) {
        return null;
    }
    // get basename
    filename = filename.replace(/^.+\//,'');
    // filename matches something like VID_2022-03-04 or PXL-20220304
    if (/^[A-Z\-_]+[12][90]\d\d/.test(filename)) {
        const matches = filename.match(/^[A-Z\-_]+(\d{4})/);
        return matches[1];
    }
    // filename is something like 20220304
    if (/^20\d\d/.test(filename)) {
        return filename.substring(0,4);
    }
    return null;

}
// compare files that may be the same
const compareFileSet = (files, setKey) => {
    const matches = [];
    let dupCount =0;
    const filesToLookup = filterLookupList(files);
    // We need at least 2 files to bother
    log.trace(`Filtered from ${files.length} to ${filesToLookup.length}`);
    if (filesToLookup.length > 1) {
        try {
            let exif = null;
            if (options.exiftool) {
                const searchArgs = filesToLookup.map(f => f.filepath);
                exif = callExifTool(searchArgs);
                log.trace(exif);
            }
            if (options.hash) {
                // adding property in place...  Feels dirty.
                filesToLookup.map(f => { 
                    if (!f.hash) {
                        log.debug(`No hash for ${f.filepath}`);
                        const hash = exifHash(f.filepath);
                        f.hash = hash;
                        return f;
                    }
                });
            }
            const tm = filesToLookup;
            for (src = 0; src < tm.length -1; src++) {
                if (!options.only || (options.only && options.keepmatch && tm[src].filepath.indexOf(options.keepmatch) !== -1)) {
                    log.trace(`Comparing from 1 to ${tm.length}`);
                    for (dst = 1; dst < tm.length; dst++) {
                        if (src !== dst && matches.indexOf(dst) === -1 && matches.indexOf(src) === -1) {
                            log.debug(`%%%% comparing files: \t${setKey}\t${tm[src].filepath}\t${tm[dst].filepath}`);
                            const [diffs,checks] = compareNodes("",tm[src],tm[dst], 0,0);
                            if (options.hash && tm[src].hash === tm[dst].hash) {
                                log.trace(`HASHES (DEL) equal: \t${setKey}\t${tm[src].filepath}\t${tm[src].hash}\t${tm[dst].filepath}\t${tm[dst].hash}`);
                                if (diffs >= 1 || checks <=2) {
                                    log.debug(`HASH match but unequal fields:\t${diffs}/${checks}\t${setKey}\t${tm[src].filepath}\t${tm[src].hash}\t${tm[dst].filepath}\t${tm[dst].hash}`);
                                }
                            }
                            if (diffs < 1 && checks >2) {
                                log.debug(`Possible duplicate: Checked ${checks}, found ${diffs} differences`);
                                const srcIsRight = isYearDirectoryCorrect(tm[src].filepath, exif ? exif[src] : setKey);
                                if (srcIsRight.isOk) {
                                    const dstIsRight = isYearDirectoryCorrect(tm[dst].filepath, exif ? exif[dst] : setKey);
                                    if (!dstIsRight.isOk) {
                                        log.info(`DST Image in wrong year:\t(${dstIsRight.fileYear} != ${dstIsRight.yearTaken})\t${diffs}\t${setKey}\tSRC:\t${tm[src].filepath}\t${tm[src].size}\tDUP:\t${tm[dst].filepath}\t${tm[dst].size}`);
                                        if (deleteFile({toDelete:tm[dst].filepath, src:tm[src].filepath})) {
                                            matches.push(dst);
                                            dupCount++;
                                        }
                                    }
                                    else if (dstIsRight.isOk) {
                                        log.info(`Duplicate images in correct year:\t(${dstIsRight.fileYear} == ${dstIsRight.yearTaken})\t${diffs}\t${setKey}\tSRC:\t${tm[src].filepath}\t${tm[src].size}\tDUP:\t${tm[dst].filepath}\t${tm[dst].size}`);
                                        if (deleteFile({toDelete:tm[dst].filepath, src:tm[src].filepath})) {
                                            matches.push(dst);
                                            dupCount++;
                                        }
                                    }
                                }
                                else {
                                    if (options.noyear) {
                                        if (deleteFile({toDelete:tm[dst].filepath, src:tm[src].filepath})) {
                                            matches.push(dst);
                                            dupCount++;
                                        }
                                    }
                                    else {
                                        const dstIsRight = isYearDirectoryCorrect(tm[dst].filepath, exif ? exif[dst] : setKey);
                                        log.info(`SRC Image in wrong year:\t(srcYear: ${srcIsRight.fileYear} != yearTaken:${srcIsRight.yearTaken})\t${diffs}\t${setKey}\tSRC:\t${tm[src].filepath}\t${tm[src].size}\tDUP:\t${tm[dst].filepath}\t${tm[dst].size}`);
                                        if (options.only && options.keepmatch && tm[dst].filepath.indexOf(options.keepmatch) !== -1 && dstIsRight.isOk) { 
                                            log.info(`Swapping SRC and DST since both match ${options.keepmatch} and DST is right year`);
                                            if (deleteFile({toDelete:tm[src].filepath, src:tm[dst].filepath})) {
                                                matches.push(dst);
                                                dupCount++;
                                            }
                                        }
                                    }
                                }
                            }
                            else {
                                log.debug(`Checked ${checks}, found ${diffs} differences, declaring different`);
                            }
                        }
                        else {
                            log.trace(`not compareing files because already marked as dup or same`);
                        }
                    }
                }
                else {
                    log.trace(`not comparing because -only is not set (only:${options.only}) or -keepmatch is set (${options.keepmatch}) and in src filepath (${tm[src].filepath})`);
                }
            }
        }
        catch (e) {
            console.error("error matching",e);
        }
    }
    log.debug(`Number of duplicates for set (${setKey}): ${dupCount}/${files.length}`);
    return dupCount;

}

const getYearInfo = (file, date) => {
    try {
        const matches = file.match(/sortedByYear\/([^\/]+).*\/([^\/]+)/);
        if (!matches) {
            return null;
        }
        const stats = fs.statSync(file);
        const year = matches[1];
        const fname = matches[2];

        const exifdata = execFileSync('exiftool', ['-j',file], {encoding: 'utf-8'});
        log.trace(exifdata);
        const jsonExif = JSON.parse(exifdata);
        
        const yearTaken=jsonExif[0].DateTimeOriginal.replace(/:.+$/,'');

        log.debug(`directory YEAR: ${year}, year taken: ${yearTaken} - fname: ${fname} - date: ${date}`);
        if (year == yearTaken) {
            log.trace("correct year");
            return true;
        }

    }
    catch (e){
        log.info(`${file} does not exist`);
        log.trace(e);
        return null;
    }
}
const getVideoTags = (file) => {
    const vid = /(mp4|mov|m4v|mpg|avi)$/i;
    if (!vid.test(file)) {
        log.trace(`not getting non movie: ${file}`);
        return null;
    }
    log.debug(`Getting video info for: ${file}`);
    const tags = callExifTool([file]);
    return tags[0];
}

const getTags = async (file) => {
    const jpg = /(jpg|jpeg)$/i;
    if (!jpg.test(file)) {
        log.trace(`not getting non JPEG: ${file}`);
        return null;
    }
    let output = {};
    try {
        log.debug(`Getting info for: ${file}`);
        output = await (exifr.parse(file,true));
        log.trace(output);
        return output;
    }
    catch (e) {
        log.error(`Error getting tags for ${file}`,e);
        return output;
    }
        
}


const compareNodes = (name,n1,n2, diffs, checks) => {
    if (typeof n1 === 'object' && n1 != null && n2 != null && typeof n2 === 'object') {
        Object.keys(n1).forEach(n => {
            if (omitFields.indexOf(n) === -1) {
                [diffs,checks] = compareNodes(`${name}.${n}`,n1[n],n2[n], diffs, checks);
            }
            else {
                log.trace(`...not comparing ${n}`);
            }
        });
    }
    else if (typeof n1 === 'object' && n1 != null && typeof n2 !== 'object') {
        log.debug(`${name} SOURCE ONLY`);
        ++diffs;
    }
    else if (typeof n1 !== 'object' && typeof n2 === 'object' && n2 != null) {
        log.debug(`${name} DEST ONLY`);
        ++diffs;
    }
    else if (n1 !== n2) {
        // allow sizes to be within 0.1% and still be the same
        const sizeDiff = Math.abs((n1 - n2)/n1);
        if (
            (name === '.size') &&
            (options.closesize) &&
            (typeof n1  === 'number' && typeof n2 === 'number') &&
            (sizeDiff < .001)
           ) { 
            log.debug(`${name} CLOSE SIZE (not dif): ${n1} within 0.1% of ${n2} (${sizeDiff}) (${typeof n1} - ${typeof n2})`);
         } else if (name === '.Warning') {
             log.debug(`Ignoring warning: (${n1}) - (${n2})`);
         }
        else {
            log.debug(`${name} DIF: ${n1} <=> ${n2} (${typeof n1} - ${typeof n2})`);
            ++diffs;
        }
    }
    ++checks;
    // Don't output anything if same
    log.trace(`${name} total diffs: ${diffs}`);
    return [diffs, checks];
}
    
const moveFile = (src, year) => {
    try {
        if (!year || year == 'null') {
            log.trace(`not moving ${src} to nonexistant ${year}`);
        }
        if (!options.movedir) {
            log.trace(`not moving ${src} to ${year} because option not set (${options.movedir})`);
            return false;
        }
        let newDir = `${options.movedir}/${year}`;
        if (!fs.existsSync(newDir)) {
            log.warn(`not moving ${src} because ${newDir} does not exist`);
            return false;
        }
        const dirStats = fs.statSync(newDir);
        if (!dirStats.isDirectory()) {
            log.warn(`not moving ${src} because ${newDir} is not a directory`);
            return false;
        }
        const filename = src.replace(/^.+\//,'');
        const prevDir = src.replace('/'+filename,'').replace(/^.+\//,'');
        if (!/^\d{4}$/.test(prevDir)) {
            newDir = newDir+'/moved/'+prevDir;
            if (!fs.existsSync(newDir)) {
                if (options.move) {
                    log.debug(`CREATING DIRECTORY FOR MOVE: ${newDir}`);
                    fs.mkdirSync(newDir, {recursive: true});
                }
                else {
                    log.debug(`WOULD CREATE DIRECTORY, but move flag off: ${newDir}`);
                }
            }
        }
        else {
            newDir = newDir + '/moved';
        }
            
        const newFile = `${newDir}/${filename}`;
        log.trace(`NEWDIR: ${newDir}`);
        let reCompareFiles = true;
        if (fs.existsSync(newFile)) {
            const exifData = callExifTool([src,newFile]);
            if (options.picasa) {
                if (picasaCheck(exifData[0],exifData[1]) === true) {
                    log.info(`PICASA: ${src} is a better version of picasa file ${newFile}`);
                    // only delete the newfile if we plan to move src to replace it
                    if (options.move) {
                        deleteFile({toDelete:newFile, src: src});
                        // fall out to move
                        reCompareFiles = false;
                    }
                    else {
                        log.warn(`not deleting ${newFile} because it exists, and move option not set to move ${src} to replace it`);
                        return false;
                    }
                }
                else if (picasaCheck(exifData[1],exifData[0]) === true) {
                    log.info(`PICASA (reverse): ${newFile} is a better version of picasa file ${src}`);
                    deleteFile({toDelete:src, src:newFile});
                    return false;
                }
                else {
                    log.trace(`${src} and ${newFile} not picasa dups`);
                }
            }
            if (reCompareFiles) {
                log.warn(`not moving ${src} because ${newFile} already exists`);
                // comparing existing files
                const [diffs,checks] = compareNodes("",exifData[0],exifData[1], 0,0);
                log.debug(`Differences with existing files: ${diffs}/${checks}`);
                if (!diffs) {
                    log.info(`SAME file in ${src} (${exifData[0].FileSize}) and ${newFile} (${exifData[1].FileSize})`);
                    // will not be actually deleted unless delete flag is set also
                    if (options.move) {
                        deleteFile({toDelete:src, src:newFile});
                    }
                }
                else {
                    // Google resize check
                    const g = exifData[0];
                    const o = exifData[1];
                    log.trace(`Encoder: ${g.Encoder}, Duration: ${g.Duration},${o.Duration}; Megapixels: ${g.Megapixels},${o.Megapixels}; Height: ${g.SourceImageHeight},${o.SourceImageHeight}, Width: ${g.SourceImageWidth},${o.SourceImageHeight}`);
                    if ((g.Encoder === 'Google') &&
                        (g.Duration && g.SourceImageWidth && g.SourceImageHeight && g.Megapixels) &&
                        (g.Duration === o.Duration) &&
                        (g.SourceImageWidth === o.SourceImageWidth) &&
                        (g.SourceImageHeight === o.SourceImageHeight) &&
                        (g.Megapixels === o.Megapixels)) {
                        log.warn(`RECODE: ${src} appears to be google recode of ${newFile}`);
                    }
                }
                return false;
            }
        }
        if (options.move) {
            log.debug(`MOVING ${src} to ${newFile}`);
            if (!fs.existsSync(newFile)) {
                fs.renameSync(src,newFile);
            }
            else {
                log.debug(`... really not moving because ${newFile} already exists`);
            }
        }
        else {
            log.debug(`not MOVING (move flag off) ${src} to ${newFile}`);
        }
        return true;
    }
    catch (e) {
        log.error(`Error renaming ${src} to ${year}`, e);
    }
}

const showStats = () => {
    if (options.stats) {
        log.info("============= Files by time key ====================")
        Object.keys(byTime).sort((a,b) => byTime[a].length - byTime[b].length).forEach(time => {
            log.info(`\t${byTime[time].length}\t${time}`);
        });
    }
    if (options.movedir || verbosity >= LOG_LEVEL.DEBUG) {
        log.info("============= Files by correct year ===================");
        let totalSize = 0;
        let wrongSize = 0;
        let correctSize = 0;
        let count = 0;
        let badCount = 0;
        let moveCount = 0;
        Object.keys(byTime).forEach(time => {
            byTime[time].forEach((item) => {
                // check directory
                if (fs.existsSync(item.filepath)) {
                    const size = fs.statSync(item.filepath).size - 0;
                    totalSize += size;
                    count++;
                    const yearIsCorrect = isYearDirectoryCorrect(item.filepath, item);
                    if (yearIsCorrect.isOk) {
                        correctSize += size;
                    }
                    else {
                        if (options.skip && options.skip.some(pattern => (item.filepath.indexOf(pattern) !== -1))) {
                            log.debug(`File in EXCLUDE LIST (not counting in stats):\tFile year:\t${yearIsCorrect.fileYear}\tTaken:\t${yearIsCorrect.yearTaken}\t${item.filepath}\tSize:\t${size}`);
                        }
                        else {
                            log.debug(`File in wrong year:\tFile year:\t${yearIsCorrect.fileYear}\tTaken:\t${yearIsCorrect.yearTaken}\t${item.filepath}\tSize:\t${size}`);
                            wrongSize += size;
                            badCount++;
                            if (options.movedir && yearIsCorrect.yearTaken) {
                                if (moveFile(item.filepath,yearIsCorrect.yearTaken)) {
                                    moveCount++;
                                }
                            }
                        }
                    }
                }
            });
        });
        log.info(`Total     size:\t${totalSize}`);
        log.info(`Bad year  size:\t${wrongSize}`);
        log.info(`Good year size:\t${correctSize}`);
        log.info(`Total    files:\t${count}`);
        log.info(`Wrong yr files:\t${badCount}`);
        log.info(`Moved    files:\t${moveCount}`);
    }

}

postReadActions = () => {

    if (options.move && !options.movedir) {
        log.error("Must have movedir option with move. Not moving files");
    }
    if (options.compare) {
        if (options.hash) {
            log.debug("Converting byTime index to byHash");
            const byHash = {}
            Object.values(byTime).forEach(arr => {
                arr.forEach(entry => {
                    if (!byHash[entry.hash]) {
                        byHash[entry.hash] = [];
                    }
                    byHash[entry.hash].push(entry);
                });
            });
            compareFiles(byHash);
        }
        else {
            compareFiles(byTime);
        }
    }
    if (options.movedir || options.stats) {
        showStats();
    }

}

// check if the second image is a lower quality picasa image of first
const picasaCheck = (exif1,exif2) => {
    log.trace(`Picasa check: ${exif1.SourceFile} =--= ${exif2.SourceFile}`);
    if (exif2.Creator !== 'Picasa') {
        log.trace(`Not from picasa: Creator: ${exif2.Creator} (${JSON.stringify(exif2,null,2)}`);
        return false;
    }
    const picasaFields = ['DateTimeOriginal','Make','Model'];
    if (!options.nothumb) {
        picasaFields.push('ThumbnailLength');
    }

    log.trace(`checking fields: ${picasaFields}`);
    const differentFields = picasaFields.reduce((accum, field) => {
        if (!exif1[field] || !exif2[field]) {
            log.trace(`Not a picasa match because ${field} missing 1:${exif1[field]}, 2:${exif2[field]}`);
            log.trace(exif1);
            return accum+1;
        }
        if (exif1[field] !== exif2[field]) {
            log.trace(`Not a picasa match because ${field} not equal 1:${exif1[field]}, 2:${exif2[field]}`);
            return accum+1;
        }
        return accum;

    },0);
    log.trace(`field equivalency check: differences: ${differentFields}`);
    if (differentFields) {
        return false;
    }

    if ((exif1.Megapixels >= exif2.Megapixels)
        &&  ((exif1.ImageWidth >= exif2.ImageWidth) && (exif1.ImageHeight >= exif2.ImageHeight))
        &&  ((exif1.SubjectArea === exif2.SubjectArea) || ((exif1.ImageWidth === exif2.RelatedImageWifth) && (exif1.ImageHeight === exif2.ImageHeight))) 
    ) {
        log.trace(`Picasa specs worse or equal to source: ${exif1.Megapixels} >= ${exif2.Megapixels}, ${exif1.ImageWidth} >= ${exif2.ImageWidth}, ${exif1.ImageHeight} >= ${exif2.ImageHeight}`);
        return true;
    }
    log.trace(`Picasa specs not worse or equal to source: ${exif1.Megapixels} !>= ${exif2.Megapixels}, ${exif1.ImageWidth} !>= ${exif2.ImageWidth}, ${exif1.ImageHeight} !>= ${exif2.ImageHeight}`);
    return false;
}
const compareFiles = (hash) =>
{
    let dupCount = 0;
        Object.keys(hash).forEach(time => {
            const tm = hash[time];
            if (time && time.indexOf('undefined') === -1 && tm.length > 1) {
                log.debug(`Fileset to compare:\t${tm.length}\t${time}`);
                dupCount += compareFileSet(tm, time);
            }
            else if (time.indexOf('undefined') !== -1) {
                if (options.undefined) {
                    log.debug(`Fileset to compare (with undefined):\t${tm.length}\t${time}`);
                    dupCount += compareFileSet(tm, time);
                }
            }
        });
    log.info("============== Compare duplicates ================");
    log.info(`Number of duplicates: ${dupCount}`);
}

const getFilesRecursively = async (directory) => {
    try {
          const filesInDirectory = fs.readdirSync(directory);
          for (const file of filesInDirectory) {
              log.trace(`checking path: ${file}`);
              const absolute = path.join(directory, file);
              const stats = fs.statSync(absolute);
              if (stats.isDirectory()) {
                  log.trace(`${absolute} is a directory`);
                  if (!files[absolute]) {
                      files[absolute] = 1;
                      await getFilesRecursively(absolute);
                  }
                  else {
                      log.warn(`Already saw directory: ${absolute}`);
                  }
              } else {
                  files[absolute] = 1;
                  log.trace(`${absolute} is a file`);
                  const tags = await getTags(absolute);
                  if (tags) {
                      const savedTags = {
                          filepath : absolute,
                          size  : stats.size
                      }
                      exifFields.forEach(field => {
                        if (tags.hasOwnProperty(field)) {
                            if (typeof tags[field] === 'object' && tags[field] instanceof Uint8Array) {
                                log.trace(`Field: ${field} - type: ${typeof tags[field]}, Uint8Array?: ${tags[field] instanceof Uint8Array}`);
                                savedTags[field] = Buffer.from(tags[field]).toString('base64');
                            }
                            else {
                                savedTags[field] = tags[field];
                            }
                        }
                      });
                      if (options.hash) {
                          savedTags.hash = exifHash(absolute);
                      }
                      let dateTaken = tags.DateTimeOriginal || tags.ModifyDate;
                      // Add size - but only if date looks fishy
                      const sizeYear = isYearDirectoryCorrect(absolute,tags);
                      const yearTaken = sizeYear.yearTaken;
                      if (!dateTaken || !yearTaken || yearTaken < 2000 || yearTaken > 2025 || stats.size < 200000) {
                          // call exiftool to get the size to add
                          const [exifData] = callExifTool([absolute]);
                          dateTaken = `${dateTaken} (${yearTaken}) - (${exifData?.ImageSize})`;
                          // we got the exifdata, so might as well add it
                          if (exifData) {
                              exifFields.forEach(field => {
                                if (exifData.hasOwnProperty(field)) {
                                    savedTags[field] = exifData[field];
                                }
                              });
                          }
                      }

                      log.trace(`using key: ${dateTaken}`);
                      if (!byTime[dateTaken]) {
                          byTime[dateTaken] = [];
                      }
                      byTime[dateTaken].push(savedTags);
                  }
              }
            }
        }
        catch (e) {
            log.error(`Error reading files`,e);
        }
};
const getFilesRecursivelySync = (directory) => {
      const filesInDirectory = fs.readdirSync(directory);
      for (const file of filesInDirectory) {
          try {
              log.trace(`checking path: ${file}`);
              const absolute = path.join(directory, file);
              const stats = fs.statSync(absolute);
              if (stats.isDirectory()) {
                  log.trace(`${absolute} is a directory`);
                  if (!files[absolute]) {
                      files[absolute] = 1;
                      getFilesRecursivelySync(absolute);
                  }
                  else {
                      log.warn(`Already saw directory: ${absolute}`);
                  }
              } else {
                  files[absolute] = 1;
                  log.trace(`${absolute} is a file`);
                  const tags = getVideoTags(absolute);
                  if (tags) {
                      const savedTags = {
                          ...tags,
                          filepath : absolute,
                          size  : stats.size
                      }
                      // doesn't quite work... maybe just hash the whole file?
                      if (options.hash) {
                          savedTags.hash = exifHash(absolute);
                      }
                      /*
                      exifFields.forEach(field => {
                        if (tags.hasOwnProperty(field)) {
                            savedTags[field] = tags[field];
                        }
                      });
                      */

                      const createTime = tags.DateTimeOriginal || tags.MediaCreateDate;
                      const duration = tags.TrackDuration || tags.Duration;
                      const dateTaken = `${createTime} DUR:${duration}`;
                      if (!byTime[dateTaken]) {
                          byTime[dateTaken] = [];
                      }
                      byTime[dateTaken].push(savedTags);
                  }
              }
          }
          catch (e) {
              log.error(`Error getting file ${file}`,e);
          }
    }
};

const replacer = (k,v) => {
    if (typeof v === 'object' && v instanceof Uint8Array) {
        return Buffer.from(v).toString('base64');
    }
    else {
        return v;
    }
}
getDirFilesSync = (directories) => {
    try {
        directories.forEach(dir => {
            log.info("getting files:",dir);
            getFilesRecursivelySync(dir);
        });
        log.info("OUTPUT:");
        if (options.save) {
            log.info(`Saving to ${options.save}`);
            fs.writeFileSync(options.save,JSON.stringify(byTime,replacer,2));
        }
        postReadActions();
    }
    catch (e) {
        log.error("get dir files error",e);
    }
}

getDirFiles = async (directories) => {
    try {
        for (let i=0;i<directories.length; i++) {
            const dir = directories[i];
            log.info("getting files:",dir);
            await getFilesRecursively(dir);
        };
        log.info("OUTPUT:");
        if (options.save) {
            log.info(`Saving to ${options.save}`);
            fs.writeFileSync(options.save,JSON.stringify(byTime,replacer,2));
        }
        postReadActions();
    }
    catch (e) {
        log.error("get dir files error",e);
    }
}

if (options.load) {
    log.info(`loading ${options.load}`);
    byTime = JSON.parse(fs.readFileSync(options.load[0]));
    for (i=1;i<options.load.length;i++) {
        const tmp = JSON.parse(fs.readFileSync(options.load[i]));
        Object.keys(tmp).forEach(k => {
            if (byTime.hasOwnProperty(k)) {
                byTime[k].push(...tmp[k]);
            }
            else {
                byTime[k] = tmp[k];
            }
        })
    }
    postReadActions();
}
if (options.dir) {
    getDirFiles(options.dir);
}
if (options.videodir) {
    getDirFilesSync(options.videodir);
}

