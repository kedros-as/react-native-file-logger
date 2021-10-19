//
//  CompressingLogFileManager.m
//  LogFileCompressor
//
//  CocoaLumberjack Demos
//

#import "CompressingLogFileManager.h"
#import <zlib.h>

// We probably shouldn't be using DDLog() statements within the DDLog implementation.
// But we still want to leave our log statements for any future debugging,
// and to allow other developers to trace the implementation (which is a great learning tool).
// 
// So we use primitive logging macros around NSLog.
// We maintain the NS prefix on the macros to be explicit about the fact that we're using NSLog.

#define LOG_LEVEL 3

#define NSLogError(frmt, ...)    do{ if(LOG_LEVEL >= 1) NSLog(frmt, ##__VA_ARGS__); } while(0)
#define NSLogWarn(frmt, ...)     do{ if(LOG_LEVEL >= 2) NSLog(frmt, ##__VA_ARGS__); } while(0)
#define NSLogInfo(frmt, ...)     do{ if(LOG_LEVEL >= 3) NSLog(frmt, ##__VA_ARGS__); } while(0)
#define NSLogVerbose(frmt, ...)  do{ if(LOG_LEVEL >= 4) NSLog(frmt, ##__VA_ARGS__); } while(0)

#if TARGET_OS_IPHONE
BOOL doesAppRunInBackground2(void);
#endif


NSUInteger         const CLFMkDDDefaultLogMaxNumLogFiles   = 5;                // 5 Files
unsigned long long const CLFMkDDDefaultLogFilesDiskQuota   = 20 * 1024 * 1024; // 20 MB

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface CompressingLogFileManager (/* Must be nameless for properties */)
{
    NSDateFormatter *_fileDateFormatter;
    NSUInteger _maximumNumberOfLogFiles;
    unsigned long long _logFilesDiskQuota;
    NSString *_logsDirectory;
#if TARGET_OS_IPHONE
    NSFileProtectionType _defaultFileProtectionLevel;
#endif
}

@property (readwrite) BOOL isCompressing;
@property (readwrite) BOOL isDeleting;

@end

@interface DDLogFileInfo (Compressor)

@property (nonatomic, readonly) BOOL isCompressed;

- (NSString *)tempFilePathByAppendingPathExtension:(NSString *)newExt;
- (NSString *)fileNameByAppendingPathExtension:(NSString *)newExt;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation CompressingLogFileManager

@synthesize maximumNumberOfLogFiles = _maximumNumberOfLogFiles;
@synthesize logFilesDiskQuota = _logFilesDiskQuota;
@synthesize isCompressing;
@synthesize isDeleting;

- (instancetype)init
{
    return [self initWithLogsDirectory:nil];
}

- (instancetype)initWithLogsDirectory:(NSString *)aLogsDirectory
{
    if ((self = [super init])) {
        upToDate = NO;
        _maximumNumberOfLogFiles = CLFMkDDDefaultLogMaxNumLogFiles;
        _logFilesDiskQuota = CLFMkDDDefaultLogFilesDiskQuota;

        _fileDateFormatter = [[NSDateFormatter alloc] init];
        [_fileDateFormatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
        [_fileDateFormatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        [_fileDateFormatter setDateFormat: @"yyyy'-'MM'-'dd'--'HH'-'mm'-'ss'-'SSS'"];

        if (aLogsDirectory.length > 0) {
            _logsDirectory = [aLogsDirectory copy];
        } else {
            _logsDirectory = [[self defaultLogsDirectory] copy];
        }

        NSLogInfo(@"CompressingLogFileManager: logsDirectory:\n%@", [self logsDirectory]);
        NSLogVerbose(@"CompressingLogFileManager: sortedLogFileNames:\n%@", [self sortedLogFileNames]);

        [self performSelector:@selector(compressNextLogFile) withObject:nil afterDelay:5.0];
    }

    return self;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(compressNextLogFile) object:nil];
}

#if TARGET_OS_IPHONE
- (instancetype)initWithLogsDirectory:(NSString *)logsDirectory
           defaultFileProtectionLevel:(NSFileProtectionType)fileProtectionLevel {

    if ((self = [self initWithLogsDirectory:logsDirectory])) {
        if ([fileProtectionLevel isEqualToString:NSFileProtectionNone] ||
            [fileProtectionLevel isEqualToString:NSFileProtectionComplete] ||
            [fileProtectionLevel isEqualToString:NSFileProtectionCompleteUnlessOpen] ||
            [fileProtectionLevel isEqualToString:NSFileProtectionCompleteUntilFirstUserAuthentication]) {
            _defaultFileProtectionLevel = fileProtectionLevel;
        }
    }

    return self;
}

#endif

- (void)deleteOldFilesForConfigurationChange {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            // See method header for queue reasoning.
            [self deleteOldLogFiles];
        }
    });
}

- (void)setLogFilesDiskQuota:(unsigned long long)logFilesDiskQuota {
    if (_logFilesDiskQuota != logFilesDiskQuota) {
        _logFilesDiskQuota = logFilesDiskQuota;
        NSLogInfo(@"CompressingLogFileManager: Responding to configuration change: logFilesDiskQuota");
        [self deleteOldFilesForConfigurationChange];
    }
}

- (void)setMaximumNumberOfLogFiles:(NSUInteger)maximumNumberOfLogFiles {
    if (_maximumNumberOfLogFiles != maximumNumberOfLogFiles) {
        _maximumNumberOfLogFiles = maximumNumberOfLogFiles;
        NSLogInfo(@"CompressingLogFileManager: Responding to configuration change: maximumNumberOfLogFiles");
        [self deleteOldFilesForConfigurationChange];
    }
}

#if TARGET_OS_IPHONE
- (NSFileProtectionType)logFileProtection {
    if (_defaultFileProtectionLevel.length > 0) {
        return _defaultFileProtectionLevel;
    } else if (doesAppRunInBackground2()) {
        return NSFileProtectionCompleteUntilFirstUserAuthentication;
    } else {
        return NSFileProtectionCompleteUnlessOpen;
    }
}
#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark File Deleting
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Deletes archived log files that exceed the maximumNumberOfLogFiles or logFilesDiskQuota configuration values.
 * Method may take a while to execute since we're performing IO. It's not critical that this is synchronized with
 * log output, since the files we're deleting are all archived and not in use, therefore this method is called on a
 * background queue.
 **/
- (void)deleteOldLogFiles {
    if (self.isDeleting) return;
    self.isDeleting = YES;

    NSArray *sortedLogFileInfos = [self sortedLogFileInfos];
    NSUInteger firstIndexToDelete = NSNotFound;

    const unsigned long long diskQuota = self.logFilesDiskQuota;
    const NSUInteger maxNumLogFiles = self.maximumNumberOfLogFiles;

    if (diskQuota) {
        unsigned long long used = 0;

        for (NSUInteger i = 0; i < sortedLogFileInfos.count; i++) {
            DDLogFileInfo *info = sortedLogFileInfos[i];
            used += info.fileSize;

            if (used > diskQuota) {
                firstIndexToDelete = i;
                break;
            }
        }
    }

    if (maxNumLogFiles) {
        if (firstIndexToDelete == NSNotFound) {
            firstIndexToDelete = maxNumLogFiles;
        } else {
            firstIndexToDelete = MIN(firstIndexToDelete, maxNumLogFiles);
        }
    }

    if (firstIndexToDelete == 0) {
        // Do we consider the first file?
        // We are only supposed to be deleting archived files.
        // In most cases, the first file is likely the log file that is currently being written to.
        // So in most cases, we do not want to consider this file for deletion.

        if (sortedLogFileInfos.count > 0) {
            DDLogFileInfo *logFileInfo = sortedLogFileInfos[0];

            if (!logFileInfo.isArchived) {
                // Don't delete active file.
                ++firstIndexToDelete;
            }
        }
    }

    if (firstIndexToDelete != NSNotFound) {
        // removing all log files starting with firstIndexToDelete

        for (NSUInteger i = firstIndexToDelete; i < sortedLogFileInfos.count; i++) {
            DDLogFileInfo *logFileInfo = sortedLogFileInfos[i];

            NSError *error = nil;
            BOOL success = [[NSFileManager defaultManager] removeItemAtPath:logFileInfo.filePath error:&error];
            if (success) {
                NSLogInfo(@"CompressingLogFileManager: Deleting file: %@", logFileInfo.fileName);
            } else {
                NSLogError(@"CompressingLogFileManager: Error deleting file %@", error);
            }
        }
    }

    self.isDeleting = NO;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Log Files
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Returns the path to the default logs directory.
 * If the logs directory doesn't exist, this method automatically creates it.
 **/
- (NSString *)defaultLogsDirectory {

#if TARGET_OS_IPHONE
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *baseDir = paths.firstObject;
    NSString *logsDirectory = [baseDir stringByAppendingPathComponent:@"Logs"];
#else
    NSString *appName = [[NSProcessInfo processInfo] processName];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *basePath = ([paths count] > 0) ? paths[0] : NSTemporaryDirectory();
    NSString *logsDirectory = [[basePath stringByAppendingPathComponent:@"Logs"] stringByAppendingPathComponent:appName];
#endif

    return logsDirectory;
}

- (NSString *)logsDirectory {
    // We could do this check once, during initialization, and not bother again.
    // But this way the code continues to work if the directory gets deleted while the code is running.

    NSAssert(_logsDirectory.length > 0, @"Directory must be set.");

    NSError *err = nil;
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:_logsDirectory
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:&err];
    if (success == NO) {
        NSLogError(@"CompressingLogFileManager: Error creating logsDirectory: %@", err);
    }

    return _logsDirectory;
}

- (BOOL)isLogFile:(NSString *)fileName {
    NSString *appName = [self applicationName];

    // We need to add a space to the name as otherwise we could match applications that have the name prefix.
    BOOL hasProperPrefix = [fileName hasPrefix:[appName stringByAppendingString:@" "]];
    BOOL hasProperSuffix = [fileName hasSuffix:@".log"] || [fileName hasSuffix:@".log.gz"];

    return (hasProperPrefix && hasProperSuffix);
}

// if you change formatter, then change sortedLogFileInfos method also accordingly
- (NSDateFormatter *)logFileDateFormatter {
    return _fileDateFormatter;
}

- (NSArray *)unsortedLogFilePaths {
    NSString *logsDirectory = [self logsDirectory];
    NSArray *fileNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:logsDirectory error:nil];

    NSMutableArray *unsortedLogFilePaths = [NSMutableArray arrayWithCapacity:[fileNames count]];

    for (NSString *fileName in fileNames) {
        // Filter out any files that aren't log files. (Just for extra safety)

#if TARGET_IPHONE_SIMULATOR
        // This is only used on the iPhone simulator for backward compatibility reason.
        //
        // In case of iPhone simulator there can be 'archived' extension. isLogFile:
        // method knows nothing about it. Thus removing it for this method.
        NSString *theFileName = [fileName stringByReplacingOccurrencesOfString:@".archived"
                                                                    withString:@""];

        if ([self isLogFile:theFileName])
#else

        if ([self isLogFile:fileName])
#endif
        {
            NSString *filePath = [logsDirectory stringByAppendingPathComponent:fileName];

            [unsortedLogFilePaths addObject:filePath];
        }
    }

    return unsortedLogFilePaths;
}

- (NSArray *)unsortedLogFileNames {
    NSArray *unsortedLogFilePaths = [self unsortedLogFilePaths];

    NSMutableArray *unsortedLogFileNames = [NSMutableArray arrayWithCapacity:[unsortedLogFilePaths count]];

    for (NSString *filePath in unsortedLogFilePaths) {
        [unsortedLogFileNames addObject:[filePath lastPathComponent]];
    }

    return unsortedLogFileNames;
}

- (NSArray *)unsortedLogFileInfos {
    NSArray *unsortedLogFilePaths = [self unsortedLogFilePaths];

    NSMutableArray *unsortedLogFileInfos = [NSMutableArray arrayWithCapacity:[unsortedLogFilePaths count]];

    for (NSString *filePath in unsortedLogFilePaths) {
        DDLogFileInfo *logFileInfo = [[DDLogFileInfo alloc] initWithFilePath:filePath];

        [unsortedLogFileInfos addObject:logFileInfo];
    }

    return unsortedLogFileInfos;
}

- (NSArray *)sortedLogFilePaths {
    NSArray *sortedLogFileInfos = [self sortedLogFileInfos];

    NSMutableArray *sortedLogFilePaths = [NSMutableArray arrayWithCapacity:[sortedLogFileInfos count]];

    for (DDLogFileInfo *logFileInfo in sortedLogFileInfos) {
        [sortedLogFilePaths addObject:[logFileInfo filePath]];
    }

    return sortedLogFilePaths;
}

- (NSArray *)sortedLogFileNames {
    NSArray *sortedLogFileInfos = [self sortedLogFileInfos];

    NSMutableArray *sortedLogFileNames = [NSMutableArray arrayWithCapacity:[sortedLogFileInfos count]];

    for (DDLogFileInfo *logFileInfo in sortedLogFileInfos) {
        [sortedLogFileNames addObject:[logFileInfo fileName]];
    }

    return sortedLogFileNames;
}

- (NSArray *)sortedLogFileInfos {
    return [[self unsortedLogFileInfos] sortedArrayUsingComparator:^NSComparisonResult(DDLogFileInfo *obj1,
                                                                                       DDLogFileInfo *obj2) {
        NSDate *date1 = [NSDate new];
        NSDate *date2 = [NSDate new];

        NSArray<NSString *> *arrayComponent = [[obj1 fileName] componentsSeparatedByString:@" "];
        if (arrayComponent.count > 0) {
            NSString *stringDate = arrayComponent.lastObject;
            stringDate = [stringDate stringByReplacingOccurrencesOfString:@".log.gz" withString:@""];
            stringDate = [stringDate stringByReplacingOccurrencesOfString:@".log" withString:@""];

#if TARGET_IPHONE_SIMULATOR
            // This is only used on the iPhone simulator for backward compatibility reason.
            stringDate = [stringDate stringByReplacingOccurrencesOfString:@".archived" withString:@""];
#endif
            date1 = [[self logFileDateFormatter] dateFromString:stringDate] ?: [obj1 creationDate];
        }

        arrayComponent = [[obj2 fileName] componentsSeparatedByString:@" "];
        if (arrayComponent.count > 0) {
            NSString *stringDate = arrayComponent.lastObject;
            stringDate = [stringDate stringByReplacingOccurrencesOfString:@".log.gz" withString:@""];
            stringDate = [stringDate stringByReplacingOccurrencesOfString:@".log" withString:@""];
#if TARGET_IPHONE_SIMULATOR
            // This is only used on the iPhone simulator for backward compatibility reason.
            stringDate = [stringDate stringByReplacingOccurrencesOfString:@".archived" withString:@""];
#endif
            date2 = [[self logFileDateFormatter] dateFromString:stringDate] ?: [obj2 creationDate];
        }

        return [date2 compare:date1 ?: [NSDate new]];
    }];

}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Creation
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

//if you change newLogFileName , then  change isLogFile method also accordingly
- (NSString *)newLogFileName {
    NSString *appName = [self applicationName];

    NSDateFormatter *dateFormatter = [self logFileDateFormatter];
    NSString *formattedDate = [dateFormatter stringFromDate:[NSDate date]];

    return [NSString stringWithFormat:@"%@ %@.log", appName, formattedDate];
}

- (nullable NSString *)logFileHeader {
    return nil;
}

- (NSData *)logFileHeaderData {
    NSString *fileHeaderStr = [self logFileHeader];

    if (fileHeaderStr.length == 0) {
        return nil;
    }

    if (![fileHeaderStr hasSuffix:@"\n"]) {
        fileHeaderStr = [fileHeaderStr stringByAppendingString:@"\n"];
    }

    return [fileHeaderStr dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSString *)createNewLogFileWithError:(NSError *__autoreleasing  _Nullable *)error {
    static NSUInteger MAX_ALLOWED_ERROR = 5;

    NSString *fileName = [self newLogFileName];
    NSString *logsDirectory = [self logsDirectory];
    NSData *fileHeader = [self logFileHeaderData];
    if (fileHeader == nil) {
        fileHeader = [NSData new];
    }

    NSUInteger attempt = 1;
    NSUInteger criticalErrors = 0;
    NSError *lastCriticalError;

    do {
        if (criticalErrors >= MAX_ALLOWED_ERROR) {
            NSLogError(@"CompressingLogFileManager: Bailing file creation, encountered %ld errors.",
                        (unsigned long)criticalErrors);
            *error = lastCriticalError;
            return nil;
        }

        NSString *actualFileName = fileName;
        if (attempt > 1) {
            NSString *extension = [actualFileName pathExtension];

            actualFileName = [actualFileName stringByDeletingPathExtension];
            actualFileName = [actualFileName stringByAppendingFormat:@" %lu", (unsigned long)attempt];

            if (extension.length) {
                actualFileName = [actualFileName stringByAppendingPathExtension:extension];
            }
        }

        NSString *filePath = [logsDirectory stringByAppendingPathComponent:actualFileName];

        NSError *currentError = nil;
        BOOL success = [fileHeader writeToFile:filePath options:NSDataWritingAtomic error:&currentError];

#if TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST
        if (success) {
            // When creating log file on iOS we're setting NSFileProtectionKey attribute to NSFileProtectionCompleteUnlessOpen.
            //
            // But in case if app is able to launch from background we need to have an ability to open log file any time we
            // want (even if device is locked). Thats why that attribute have to be changed to
            // NSFileProtectionCompleteUntilFirstUserAuthentication.
            NSDictionary *attributes = @{NSFileProtectionKey: [self logFileProtection]};
            success = [[NSFileManager defaultManager] setAttributes:attributes
                                                       ofItemAtPath:filePath
                                                              error:&currentError];
        }
#endif

        if (success) {
            NSLogVerbose(@"CompressingLogFileManager: Created new log file: %@", actualFileName);
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // Since we just created a new log file, we may need to delete some old log files
                [self deleteOldLogFiles];
            });
            return filePath;
        } else if (currentError.code == NSFileWriteFileExistsError) {
            attempt++;
            continue;
        } else {
            NSLogError(@"CompressingLogFileManager: Critical error while creating log file: %@", currentError);
            criticalErrors++;
            lastCriticalError = currentError;
            continue;
        }

        return filePath;
    } while (YES);
}

- (void)compressLogFile:(DDLogFileInfo *)logFile
{
    self.isCompressing = YES;

    CompressingLogFileManager* __weak weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [weakSelf backgroundThread_CompressLogFile:logFile];
    });
}

- (void)compressNextLogFile
{
    if (self.isCompressing)
    {
        // We're already compressing a file.
        // Wait until it's done to move onto the next file.
        return;
    }
    
    NSLogVerbose(@"CompressingLogFileManager: compressNextLogFile");
    
    upToDate = NO;
    
    NSArray *sortedLogFileInfos = [self sortedLogFileInfos];
    
    NSUInteger count = [sortedLogFileInfos count];
    if (count == 0)
    {
        // Nothing to compress
        upToDate = YES;
        return;
    }
    
    NSUInteger i = count;
    while (i > 0)
    {
        DDLogFileInfo *logFileInfo = [sortedLogFileInfos objectAtIndex:(i - 1)];
        
        if (logFileInfo.isArchived && !logFileInfo.isCompressed)
        {
            [self compressLogFile:logFileInfo];
            
            break;
        }
        
        i--;
    }
    
    upToDate = YES;
}

- (void)compressionDidSucceed:(DDLogFileInfo *)logFile
{
    NSLogVerbose(@"CompressingLogFileManager: compressionDidSucceed: %@", logFile.fileName);
    
    self.isCompressing = NO;
    
    [self compressNextLogFile];
}

- (void)compressionDidFail:(DDLogFileInfo *)logFile
{
    NSLogWarn(@"CompressingLogFileManager: compressionDidFail: %@", logFile.fileName);
    
    self.isCompressing = NO;
    
    // We should try the compression again, but after a short delay.
    // 
    // If the compression failed there is probably some filesystem issue,
    // so flooding it with compression attempts is only going to make things worse.
    
    NSTimeInterval delay = (60 * 15); // 15 minutes
    
    [self performSelector:@selector(compressNextLogFile) withObject:nil afterDelay:delay];
}

- (void)didArchiveLogFile:(NSString *)logFilePath wasRolled:(BOOL)wasRolled {
    NSLogVerbose(@"CompressingLogFileManager: didArchiveLogFile: %@ wasRolled: %@",
                 [logFilePath lastPathComponent], (wasRolled ? @"YES" : @"NO"));

    // If all other log files have been compressed, then we can get started right away.
    // Otherwise we should just wait for the current compression process to finish.

    if (upToDate)
    {
        [self compressLogFile:[DDLogFileInfo logFileWithPath:logFilePath]];
    }
}

- (void)backgroundThread_CompressLogFile:(DDLogFileInfo *)logFile
{
    @autoreleasepool {
    
    NSLogInfo(@"CompressingLogFileManager: Compressing log file: %@", logFile.fileName);
    
    // Steps:
    //  1. Create a new file with the same fileName, but added "gzip" extension
    //  2. Open the new file for writing (output file)
    //  3. Open the given file for reading (input file)
    //  4. Setup zlib for gzip compression
    //  5. Read a chunk of the given file
    //  6. Compress the chunk
    //  7. Write the compressed chunk to the output file
    //  8. Repeat steps 5 - 7 until the input file is exhausted
    //  9. Close input and output file
    // 10. Teardown zlib
    
    
    // STEP 1
    
    NSString *inputFilePath = logFile.filePath;
    
    NSString *tempOutputFilePath = [logFile tempFilePathByAppendingPathExtension:@"gz"];
    
#if TARGET_OS_IPHONE
    // We use the same protection as the original file.  This means that it has the same security characteristics.
    // Also, if the app can run in the background, this means that it gets
    // NSFileProtectionCompleteUntilFirstUserAuthentication so that we can do this compression even with the
    // device locked.  c.f. DDFileLogger.doesAppRunInBackground.
    NSString* protection = logFile.fileAttributes[NSFileProtectionKey];
    NSDictionary* attributes = protection == nil ? nil : @{NSFileProtectionKey: protection};
    [[NSFileManager defaultManager] createFileAtPath:tempOutputFilePath contents:nil attributes:attributes];
#endif
    
    // STEP 2 & 3
    
    NSInputStream *inputStream = [NSInputStream inputStreamWithFileAtPath:inputFilePath];
    NSOutputStream *outputStream = [NSOutputStream outputStreamToFileAtPath:tempOutputFilePath append:NO];
    
    [inputStream open];
    [outputStream open];
    
    // STEP 4
    
    z_stream strm;
    
    // Zero out the structure before (to be safe) before we start using it
    bzero(&strm, sizeof(strm));
    
    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;
    strm.opaque = Z_NULL;
    strm.total_out = 0;
    
    // Compresssion Levels:
    //   Z_NO_COMPRESSION
    //   Z_BEST_SPEED
    //   Z_BEST_COMPRESSION
    //   Z_DEFAULT_COMPRESSION
    
    deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, (15+16), 8, Z_DEFAULT_STRATEGY);
    
    // Prepare our variables for steps 5-7
    // 
    // inputDataLength  : Total length of buffer that we will read file data into
    // outputDataLength : Total length of buffer that zlib will output compressed bytes into
    // 
    // Note: The output buffer can be smaller than the input buffer because the
    //       compressed/output data is smaller than the file/input data (obviously).
    // 
    // inputDataSize : The number of bytes in the input buffer that have valid data to be compressed.
    // 
    // Imagine compressing a tiny file that is actually smaller than our inputDataLength.
    // In this case only a portion of the input buffer would have valid file data.
    // The inputDataSize helps represent the portion of the buffer that is valid.
    // 
    // Imagine compressing a huge file, but consider what happens when we get to the very end of the file.
    // The last read will likely only fill a portion of the input buffer.
    // The inputDataSize helps represent the portion of the buffer that is valid.
    
    NSUInteger inputDataLength  = (1024 * 2);  // 2 KB
    NSUInteger outputDataLength = (1024 * 1);  // 1 KB
    
    NSMutableData *inputData = [NSMutableData dataWithLength:inputDataLength];
    NSMutableData *outputData = [NSMutableData dataWithLength:outputDataLength];
    
    NSUInteger inputDataSize = 0;
    
    BOOL done = YES;
    NSError* error = nil;
    do
    {
        @autoreleasepool {
        
        // STEP 5
        // Read data from the input stream into our input buffer.
        // 
        // inputBuffer : pointer to where we want the input stream to copy bytes into
        // inputBufferLength : max number of bytes the input stream should read
        // 
        // Recall that inputDataSize is the number of valid bytes that already exist in the
        // input buffer that still need to be compressed.
        // This value is usually zero, but may be larger if a previous iteration of the loop
        // was unable to compress all the bytes in the input buffer.
        // 
        // For example, imagine that we ready 2K worth of data from the file in the last loop iteration,
        // but when we asked zlib to compress it all, zlib was only able to compress 1.5K of it.
        // We would still have 0.5K leftover that still needs to be compressed.
        // We want to make sure not to skip this important data.
        // 
        // The [inputData mutableBytes] gives us a pointer to the beginning of the underlying buffer.
        // When we add inputDataSize we get to the proper offset within the buffer
        // at which our input stream can start copying bytes into without overwriting anything it shouldn't.
        
        const void *inputBuffer = [inputData mutableBytes] + inputDataSize;
        NSUInteger inputBufferLength = inputDataLength - inputDataSize;
        
        NSInteger readLength = [inputStream read:(uint8_t *)inputBuffer maxLength:inputBufferLength];
        if (readLength < 0) {
            error = [inputStream streamError];
            break;
        }
        
        NSLogVerbose(@"CompressingLogFileManager: Read %li bytes from file", (long)readLength);
        
        inputDataSize += readLength;
        
        // STEP 6
        // Ask zlib to compress our input buffer.
        // Tell it to put the compressed bytes into our output buffer.
        
        strm.next_in = (Bytef *)[inputData mutableBytes];   // Read from input buffer
        strm.avail_in = (uInt)inputDataSize;                // as much as was read from file (plus leftovers).
        
        strm.next_out = (Bytef *)[outputData mutableBytes]; // Write data to output buffer
        strm.avail_out = (uInt)outputDataLength;            // as much space as is available in the buffer.
        
        // When we tell zlib to compress our data,
        // it won't directly tell us how much data was processed.
        // Instead it keeps a running total of the number of bytes it has processed.
        // In other words, every iteration from the loop it increments its total values.
        // So to figure out how much data was processed in this iteration,
        // we fetch the totals before we ask it to compress data,
        // and then afterwards we subtract from the new totals.
        
        NSInteger prevTotalIn = strm.total_in;
        NSInteger prevTotalOut = strm.total_out;
        
        int flush = [inputStream hasBytesAvailable] ? Z_SYNC_FLUSH : Z_FINISH;
        deflate(&strm, flush);
        
        NSInteger inputProcessed = strm.total_in - prevTotalIn;
        NSInteger outputProcessed = strm.total_out - prevTotalOut;
        
        NSLogVerbose(@"CompressingLogFileManager: Total bytes uncompressed: %lu", (unsigned long)strm.total_in);
        NSLogVerbose(@"CompressingLogFileManager: Total bytes compressed: %lu", (unsigned long)strm.total_out);
        NSLogVerbose(@"CompressingLogFileManager: Compression ratio: %.1f%%",
                     (1.0F - (float)(strm.total_out) / (float)(strm.total_in)) * 100);
        
        // STEP 7
        // Now write all compressed bytes to our output stream.
        // 
        // It is theoretically possible that the write operation doesn't write everything we ask it to.
        // Although this is highly unlikely, we take precautions.
        // Also, we watch out for any errors (maybe the disk is full).
        
        NSUInteger totalWriteLength = 0;
        NSInteger writeLength = 0;
        
        do
        {
            const void *outputBuffer = [outputData mutableBytes] + totalWriteLength;
            NSUInteger outputBufferLength = outputProcessed - totalWriteLength;
            
            writeLength = [outputStream write:(const uint8_t *)outputBuffer maxLength:outputBufferLength];
            
            if (writeLength < 0)
            {
                error = [outputStream streamError];
            }
            else
            {
                totalWriteLength += writeLength;
            }
            
        } while((totalWriteLength < outputProcessed) && !error);
        
        // STEP 7.5
        // 
        // We now have data in our input buffer that has already been compressed.
        // We want to remove all the processed data from the input buffer,
        // and we want to move any unprocessed data to the beginning of the buffer.
        // 
        // If the amount processed is less than the valid buffer size, we have leftovers.
        
        NSUInteger inputRemaining = inputDataSize - inputProcessed;
        if (inputRemaining > 0)
        {
            void *inputDst = [inputData mutableBytes];
            void *inputSrc = [inputData mutableBytes] + inputProcessed;
            
            memmove(inputDst, inputSrc, inputRemaining);
        }
        
        inputDataSize = inputRemaining;
        
        // Are we done yet?
        
        done = ((flush == Z_FINISH) && (inputDataSize == 0));
        
        // STEP 8
        // Loop repeats until end of data (or unlikely error)
        
        } // end @autoreleasepool
        
    } while (!done && error == nil);
    
    // STEP 9
    
    [inputStream close];
    [outputStream close];
    
    // STEP 10
    
    deflateEnd(&strm);
    
    // We're done!
    // Report success or failure back to the logging thread/queue.
    
    if (error)
    {
        // Remove output file.
        // Our compression attempt failed.

        NSLogError(@"Compression of %@ failed: %@", inputFilePath, error);
        error = nil;
        BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:tempOutputFilePath error:&error];
        if (!ok)
            NSLogError(@"Failed to clean up %@ after failed compression: %@", tempOutputFilePath, error);
        
        // Report failure to class via logging thread/queue
        
        dispatch_async([DDLog loggingQueue], ^{ @autoreleasepool {
            
            [self compressionDidFail:logFile];
        }});
    }
    else
    {
        // Remove original input file.
        // It will be replaced with the new compressed version.

        error = nil;
        BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:inputFilePath error:&error];
        if (!ok)
            NSLogWarn(@"Warning: failed to remove original file %@ after compression: %@", inputFilePath, error);
        
        // Mark the compressed file as archived,
        // and then move it into its final destination.
        // 
        // temp-log-ABC123.txt.gz -> log-ABC123.txt.gz
        // 
        // The reason we were using the "temp-" prefix was so the file would not be
        // considered a log file while it was only partially complete.
        // Only files that begin with "log-" are considered log files.
        
        DDLogFileInfo *compressedLogFile = [DDLogFileInfo logFileWithPath:tempOutputFilePath];
        compressedLogFile.isArchived = YES;
        
        NSString *outputFileName = [logFile fileNameByAppendingPathExtension:@"gz"];
        [compressedLogFile renameFile:outputFileName];
        
        // Report success to class via logging thread/queue
        
        dispatch_async([DDLog loggingQueue], ^{ @autoreleasepool {
            
            [self compressionDidSucceed:compressedLogFile];
        }});
    }
    
    } // end @autoreleasepool
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utility
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSString *)applicationName {
    static NSString *_appName;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        _appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"];

        if (_appName.length == 0) {
            _appName = [[NSProcessInfo processInfo] processName];
        }

        if (_appName.length == 0) {
            _appName = @"";
        }
    });

    return _appName;
}
                 
@end



////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation DDLogFileInfo (Compressor)

@dynamic isCompressed;

- (BOOL)isCompressed
{
    return [[[self fileName] pathExtension] isEqualToString:@"gz"];
}

- (NSString *)tempFilePathByAppendingPathExtension:(NSString *)newExt
{
    // Example:
    // 
    // Current File Name: "/full/path/to/log-ABC123.txt"
    // 
    // newExt: "gzip"
    // result: "/full/path/to/temp-log-ABC123.txt.gzip"
    
    NSString *tempFileName = [NSString stringWithFormat:@"temp-%@", [self fileName]];
    
    NSString *newFileName = [tempFileName stringByAppendingPathExtension:newExt];
    
    NSString *fileDir = [[self filePath] stringByDeletingLastPathComponent];
    
    NSString *newFilePath = [fileDir stringByAppendingPathComponent:newFileName];
    
    return newFilePath;
}

- (NSString *)fileNameByAppendingPathExtension:(NSString *)newExt
{
    // Example:
    // 
    // Current File Name: "log-ABC123.txt"
    // 
    // newExt: "gzip"
    // result: "log-ABC123.txt.gzip"
    
    NSString *fileNameExtension = [[self fileName] pathExtension];
    
    if ([fileNameExtension isEqualToString:newExt])
    {
        return [self fileName];
    }
    
    return [[self fileName] stringByAppendingPathExtension:newExt];
}

@end

#if TARGET_OS_IPHONE
/**
 * When creating log file on iOS we're setting NSFileProtectionKey attribute to NSFileProtectionCompleteUnlessOpen.
 *
 * But in case if app is able to launch from background we need to have an ability to open log file any time we
 * want (even if device is locked). Thats why that attribute have to be changed to
 * NSFileProtectionCompleteUntilFirstUserAuthentication.
 */
BOOL doesAppRunInBackground2() {
    BOOL answer = NO;

    NSArray *backgroundModes = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIBackgroundModes"];

    for (NSString *mode in backgroundModes) {
        if (mode.length > 0) {
            answer = YES;
            break;
        }
    }

    return answer;
}

#endif
