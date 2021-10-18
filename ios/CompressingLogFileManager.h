//
//  CompressingLogFileManager.h
//  LogFileCompressor
//
//  CocoaLumberjack Demos
//

#import <Foundation/Foundation.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

@interface CompressingLogFileManager : NSObject <DDLogFileManager>
{
    BOOL upToDate;
    BOOL isCompressing;
    BOOL isDeleting;
}

/**
 *  Default initializer
 */
- (instancetype)init;

/**
 *  If logDirectory is not specified, then a folder called "Logs" is created in the app's cache directory.
 *  While running on the simulator, the "Logs" folder is located in the library temporary directory.
 */
- (instancetype)initWithLogsDirectory:(nullable NSString *)logsDirectory NS_DESIGNATED_INITIALIZER;

#if TARGET_OS_IPHONE
/*
 * Calling this constructor you can override the default "automagically" chosen NSFileProtection level.
 * Useful if you are writing a command line utility / CydiaSubstrate addon for iOS that has no NSBundle
 * or like SpringBoard no BackgroundModes key in the NSBundle:
 *    iPhone:~ root# cycript -p SpringBoard
 *    cy# [NSBundle mainBundle]
 *    #"NSBundle </System/Library/CoreServices/SpringBoard.app> (loaded)"
 *    cy# [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIBackgroundModes"];
 *    null
 *    cy#
 **/
- (instancetype)initWithLogsDirectory:(nullable NSString *)logsDirectory
           defaultFileProtectionLevel:(NSFileProtectionType)fileProtectionLevel;
#endif

/*
 * Methods to override.
 *
 * Log files are named `"<bundle identifier> <date> <time>.log"`
 * Example: `com.organization.myapp 2013-12-03 17-14.log`
 *
 * If you wish to change default filename, you can override following two methods.
 * - `newLogFileName` method would be called on new logfile creation.
 * - `isLogFile:` method would be called to filter log files from all other files in logsDirectory.
 *   You have to parse given filename and return YES if it is logFile.
 *
 * **NOTE**
 * `newLogFileName` returns filename. If appropriate file already exists, number would be added
 * to filename before extension. You have to handle this case in isLogFile: method.
 *
 * Example:
 * - newLogFileName returns `"com.organization.myapp 2013-12-03.log"`,
 *   file `"com.organization.myapp 2013-12-03.log"` would be created.
 * - after some time `"com.organization.myapp 2013-12-03.log"` is archived
 * - newLogFileName again returns `"com.organization.myapp 2013-12-03.log"`,
 *   file `"com.organization.myapp 2013-12-03 2.log"` would be created.
 * - after some time `"com.organization.myapp 2013-12-03 1.log"` is archived
 * - newLogFileName again returns `"com.organization.myapp 2013-12-03.log"`,
 *   file `"com.organization.myapp 2013-12-03 3.log"` would be created.
 **/

/**
 * Generates log file name with default format `"<bundle identifier> <date> <time>.log"`
 * Example: `MobileSafari 2013-12-03 17-14.log`
 *
 * You can change it by overriding `newLogFileName` and `isLogFile:` methods.
 **/
@property (readonly, copy) NSString *newLogFileName;

/**
 * Default log file name is `"<bundle identifier> <date> <time>.log"`.
 * Example: `MobileSafari 2013-12-03 17-14.log`
 *
 * You can change it by overriding `newLogFileName` and `isLogFile:` methods.
 **/
- (BOOL)isLogFile:(NSString *)fileName NS_SWIFT_NAME(isLogFile(withName:));

/**
 * New log files are created empty by default in `createNewLogFile:` method
 *
 * If you wish to specify a common file header to use in your log files,
 * you can set the initial log file contents by overriding `logFileHeader`
 **/
@property (readonly, copy, nullable) NSString *logFileHeader;

/* Inherited from DDLogFileManager protocol:
   @property (readwrite, assign, atomic) NSUInteger maximumNumberOfLogFiles;
   @property (readwrite, assign, atomic) NSUInteger logFilesDiskQuota;
   - (NSString *)logsDirectory;
   - (NSArray *)unsortedLogFilePaths;
   - (NSArray *)unsortedLogFileNames;
   - (NSArray *)unsortedLogFileInfos;
   - (NSArray *)sortedLogFilePaths;
   - (NSArray *)sortedLogFileNames;
   - (NSArray *)sortedLogFileInfos;
 */

@end
