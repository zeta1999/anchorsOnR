#' Shutdown the anchors java server.
#'
#' Attempts to shutdown a running Anchors instance.
#' @param control Object of class \code{anchors_control}. Must have a slot \code{connection} representing a socketConnection.
#' @return this method will shutdown the socketConnection and return a nullified control object.
#' @export
shutdown <- function(control = NULL){
  if(is.null(control$connection)){
    BBmisc::stopf("AnchorsControl Object does not maintain a connection object")
  }


  con = control$connection

  message("Shutting down Anchors JVM: ", appendLF = FALSE);
  quitmessage = list("quit" = 1)
  quitmessage = as.character(jsonlite::toJSON(quitmessage, auto_unbox = T))
  writeLines(quitmessage, con)

  close(con)
  message("Anchors has been successfully terminated.")
  control <- NULL
  return(control)
}


#' Initialize and Connect to anchors
#'
#' By default, this method first checks if an anchors instance is available to connect to. If it cannot connect and \code{startAnchors = TRUE}, it will attempt to start an instance of anchors at localhost:6666.
#' If an open ip and port of your choice are passed in, then this method will attempt to start an anchors instance at that specified ip port.
#'
#' When initializing anchors locally, this method searches for RemoteModuleExtension.jar in the R library resources (\code{system.file("java", "RemoveModuleExtension.jar", package = "anchors")}), and if the file does not exist, it will automatically attempt to download the correct version from Maven. The user must have Internet access for this process to be successful.
#'
#' Attempts to start and/or connect to an Anchors instance.
#' @param ip Object of class \code{character} representing the IP address of the server where Anchors is running.
#' @param port Object of class \code{numeric} representing the port number of the Anchors server.
#' @param name (Optional) A \code{character} string representing the Anchors cluster name.
#' @param startAnchors (Optional) A \code{logical} value indicating whether to try to start Anchors from R if no connection with Anchors is detected. This is only possible if \code{ip = "localhost"} or \code{ip = "127.0.0.1"}.  If an existing connection is detected, R does not start Anchors.
#' @param explainer An \code{explainer} object holding startup params for the server
#' @param forceDL (Optional) A \code{logical} value indicating whether to force download of the RemoteModuleExtension executable. Defaults to FALSE, so the executable will only be downloaded if it does not already exist in the anchors R library resources directory \code{anchors/java/RemoteModuleExtension.jar}. This value is only used when R starts anchors.
#' @return this method will load and return a socketConnection
#' @export
initAnchors <- function(ip = "localhost", port = 6666, name = NA_character_,
                        startAnchors = TRUE, explainer = NULL, forceDL = FALSE) {

  if(!is.character(ip) || length(ip) != 1L || is.na(ip) || !nzchar(ip))
    stop("`ip` must be a non-empty character string")
  if(!is.numeric(port) || length(port) != 1L || is.na(port) || port < 0 || port > 65536)
    stop("`port` must be an integer ranging from 0 to 65536")
  if(!is.character(name) && !nzchar(name))
    stop("`name` must be a character string or NA_character_")
  if(!is.logical(startAnchors) || length(startAnchors) != 1L || is.na(startAnchors))
    stop("`startAnchors` must be TRUE or FALSE")

  con = NULL

  con = tryCatch({
    con = socketConnection(host = ip, port = port, blocking = F, timeout = 1)
  }, error = function(cond){
    # no need to handle failure
  }, warning = function(cond){
    # no need to handle failure
  })

  if (is.null(con) && startAnchors == TRUE){
    if (ip == "localhost" || ip == "127.0.0.1"){
      message("\nAnchors is not running yet, starting it now...\n")
      stdout <- .anchors.getTmpFile("stdout")
      .anchors.startJar(ip = ip, port = port, name = name, stdout = stdout, explainer = explainer, forceDL = forceDL)

      message("Starting Anchors JVM and connecting: ")
      Sys.sleep(1L)
      con = tryCatch({
        con = socketConnection(host = ip, port = port, blocking = F, timeout = 10L)
      }, error = function(cond){
        message(cond)
        return(NULL)
      }, warning = function(cond) {
        message(cond)
        return(NULL)
      })
    }
  } else if(is.null(con) && startAnchors == FALSE){
    BBmisc::stopf("No running instance of Anchors found. Set 'startAnchors = TRUE' to start an Anchors instance.")
    return (NULL)
  }

  if (is.null(con)){
    stop("Anchors failed to start, stopping execution.")
  }
  message("Successfully connected to anchorj!\n")
  .anchors.jar.env$port <- port #Ensure right port is called when quitting R

  return(con)
}


.anchors.pkg.path <- NULL
.anchors.pkg.path <- system.file("java", "RemoteModuleExtension.jar", package = "anchors")
.anchors.jar.env <- new.env()    # Dummy variable used to shutdown Anchors when R exits

.onLoad <- function(lib, pkg) {
  .anchors.pkg.path <<- file.path(lib, pkg)

  # installing RCurl requires curl and curl-config, which is typically separately installed
  rcurl_package_is_installed = length(find.package("RCurl", quiet = TRUE)) > 0L
  if(!rcurl_package_is_installed) {
    if(.Platform$OS.type == "unix") {
      curl_path <- Sys.which("curl-config")
      if(!nzchar(curl_path[[1L]]) || system2(curl_path, args = "--version") != 0L)
        stop("libcurl not found. Please install libcurl\n",
             "(version 7.14.0 or higher) from http://curl.haxx.se.\n",
             "On Linux systems you will often have to explicitly install\n",
             "libcurl-devel to have the header files and the libcurl library.")
    }
  }
}

#
# Returns error string if the check finds a problem with version.
# This implementation is supposed to blacklist known unsupported versions.
#
.anchors.check_java_version <- function(jver = NULL) {
  if(any(grepl("GNU libgcj", jver))) {
    return("Sorry, GNU Java is not supported for Anchors.")
  }
  if (any(grepl("^java version \"1\\.[1-7]\\.", jver))) {
    return(paste0("Your java is not supported: ", jver[1]))
  }
  return(NULL)
}


.anchors.startJar <- function(ip = "localhost", port = NULL, name = NULL, nthreads = -1,
                              max_memory = NULL, min_memory = NULL,
                              forceDL = FALSE, extra_classpath = NULL,
                              stdout, explainer = NULL) {

  command <- .anchors.checkJava()


  # Note: Logging to stdout and stderr in Windows only works for R version 3.0.2 or later!
  stderr <- .anchors.getTmpFile("stderr")
  write(Sys.getpid(), .anchors.getTmpFile("pid"), append = FALSE)   # Write PID to file to track if R started anchors

  jar_file <- .anchors.downloadJar(overwrite = forceDL)
  jar_file <- paste0('"', jar_file, '"')

  # Throw an error if GNU Java is being used
  if (.Platform$OS.type == "windows") {
    command <- normalizePath(gsub("\"","",command))
  }

  jver <- tryCatch({system2(command, "-version", stdout = TRUE, stderr = TRUE)},
                   error = function(err) {
                     print(err)
                     stop("You have a 32-bit version of Java. Anchors works best with 64-bit Java.\n",
                          "Please download the latest Java SE JDK 8 from the following URL:\n",
                          "http://www.oracle.com/technetwork/java/javase/downloads/jdk8-downloads-2133151.html")
                   }
  )
  jver_error <- .anchors.check_java_version(jver);
  if (!is.null(jver_error)) {
    stop(jver_error, "\n",
         "Please download the latest Java SE JDK 8 from the following URL:\n",
         "http://www.oracle.com/technetwork/java/javase/downloads/jdk8-downloads-2133151.html")
  }
  if(any(grepl("Client VM", jver))) {
    warning("You have a 32-bit version of Java. Anchors works best with 64-bit Java.\n",
            "Please download the latest Java SE JDK 8 from the following URL:\n",
            "http://www.oracle.com/technetwork/java/javase/downloads/jdk8-downloads-2133151.html")
    # Set default max_memory to be 1g for 32-bit JVM.
    if(is.null(max_memory)) max_memory = "1g"
  }

  # Compose args
  mem_args <- c()
  if(!is.null(min_memory)) mem_args <- c(mem_args, paste0("-Xms", min_memory))
  if(!is.null(max_memory)) mem_args <- c(mem_args, paste0("-Xmx", max_memory))

  args <- mem_args
  ltrs <- paste0(sample(letters,3, replace = TRUE), collapse="")
  nums <- paste0(sample(0:9, 3,  replace = TRUE),     collapse="")

  if(is.na(name)) name <- paste0("Anchors_started_from_R_", gsub("\\s", "_", Sys.info()["user"]),"_",ltrs,nums)
  .anchors.jar.env$name <- name

  class_path <- paste0(c(jar_file, extra_classpath), collapse=.Platform$path.sep)
  args <- c(args, "-jar", jar_file)
  args <- c(args, "-port", port)

  # Time in seconds. Small numbers should be enough so the JVM automatically powers off,
  # when explanation killed by ESC
  args <- c(args, "-timeout", 30)

  args <- c(args, "-maxAnchorSize", explainer$maxAnchors)
  args <- c(args, "-beamSize", explainer$beams)
  args <- c(args, "-delta", explainer$delta)
  args <- c(args, "-epsilon", explainer$epsilon)
  args <- c(args, "-tau", explainer$tau)
  args <- c(args, "-tauDiscrepancy", explainer$tauDiscrepancy)
  args <- c(args, "-initSampleCount", explainer$initSamples)
  args <- c(args, "-allowSuboptimalSteps", tolower(as.character(explainer$allowSuboptimalSteps)))
  args <- c(args, "-batchSize", explainer$batchSize)
  #args <- c(args, "-emptyRuleEvaluations", explainer$emptyRuleEvaluations) TODO: Why is this option removed from the java server?

   message(        "Note:  In case of errors look at the following log files:")
   message(sprintf("    %s", stdout))
   message(sprintf("    %s", stderr))
   message("\n")

  # Print a java -version to the console
  system2(command, c(mem_args, "-version"), wait = T)
  message("\n")
  # Run the real anchors java command
  rc = system2(command,
               args=args,
               stdout=stdout,
               stderr=stderr,
               wait=F)
  if (rc != 0L) {
    stop(sprintf("Failed to exec %s with return code=%s", jar_file, as.character(rc)))
  }
}


.anchors.getTmpFile <- function(type) {
  if(missing(type) || !(type %in% c("stdout", "stderr", "pid")))
    stop("type must be one of 'stdout', 'stderr', or 'pid'")

  if(.Platform$OS.type == "windows") {
    usr <- gsub("[^A-Za-z0-9]", "_", Sys.getenv("USERNAME", unset="UnknownUser"))
  } else {
    usr <- gsub("[^A-Za-z0-9]", "_", Sys.getenv("USER", unset="UnknownUser"))
  }

  if(type == "stdout")
    file.path(tempdir(), paste("anchors", usr, "started_from_r.out", sep="_"))
  else if(type == "stderr")
    file.path(tempdir(), paste("anchors", usr, "started_from_r.err", sep="_"))
  else
    file.path(tempdir(), paste("anchors", usr, "started_from_r.pid", sep="_"))
}


.anchors.checkJava <- function() {
  if(nzchar(Sys.getenv("JAVA_HOME"))) {
    if(.Platform$OS.type == "windows") { file.path(Sys.getenv("JAVA_HOME"), "bin", "java.exe") }
    else                               { file.path(Sys.getenv("JAVA_HOME"), "bin", "java") }
  }
  else if(.Platform$OS.type == "windows") {
    # Note: Should we require the version (32/64-bit) of Java to be the same as the version of R?
    prog_folder <- c("Program Files", "Program Files (x86)")
    for(prog in prog_folder) {
      prog_path <- file.path("C:", prog, "Java")
      java_folder <- list.files(prog_path)

      for(java in java_folder) {
        path <- file.path(prog_path, java, "bin", "java.exe")
        if(file.exists(path)) return(path)
      }
    }
  }
  else if(nzchar(Sys.which("java")))
    Sys.which("java")
  else
    stop("Cannot find Java. Please install the latest JRE from\n",
         "http://www.oracle.com/technetwork/java/javase/downloads/index.html")
}

# This function returns a string to the valid path on the local filesystem of the anchors.jar file,
# or it calls stop() and does not return.
# It will download a jar file if it needs to.
.anchors.downloadJar <- function(overwrite = FALSE) {
  if(!is.logical(overwrite) || length(overwrite) != 1L || is.na(overwrite)) stop("`overwrite` must be TRUE or FALSE")
  .anchors.pkg.path <- system.file("java", "RemoteModuleExtension.jar", package = "anchors")
  # PUBDEV-3534 hook to use arbitrary anchors.jar
  own_jar = Sys.getenv("ANCHORS_JAR_PATH")
  is_url = function(x) any(grepl("^(http|ftp)s?://", x), grepl("^(http|ftp)s://", x))
  if (nzchar(own_jar) && !is_url(own_jar)) {
    if (!file.exists(own_jar))
      stop(sprintf("Environment variable ANCHORS_JAR_PATH is set to '%s' but file does not exists, unset environment variable or provide valid path to anchors.jar file.", own_jar))
    return(own_jar)
  }

  if (!overwrite && !is.null(.anchors.pkg.path) && .anchors.pkg.path != ""){
    return(.anchors.pkg.path)
  }

  if (is.null(.anchors.pkg.path) || .anchors.pkg.path == "") {
    pkg_path = dirname(system.file(".", package = "anchors"))
  } else {
    pkg_path = .anchors.pkg.path
  }

  # Check for jar file in 'java' directory.
  if (! overwrite) {
    possible_file <- file.path(pkg_path, "java", "RemoteModuleExtension.jar")
    if (file.exists(possible_file)) {
      return(possible_file)
    }
  }

  # Check for jar file in 'inst/java' directory.
  if (! overwrite) {
    possible_file <- file.path(pkg_path, "inst", "java", "RemoteModuleExtension.jar")
    if (file.exists(possible_file)) {
      return(possible_file)
    }
  }

  jarFile <- file.path(pkg_path, "jar.txt")
  if (file.exists(jarFile) && !nzchar(own_jar))
    own_jar <- readLines(jarFile)

  dest_folder <- file.path(pkg_path, "java")
  if (!file.exists(dest_folder)) {
    dir.create(dest_folder)
  }

  dest_file <- file.path(dest_folder, "RemoteModuleExtension.jar")

  buildnumFile <- file.path(pkg_path, "buildnum.txt")
  version <- readLines(buildnumFile)

  # Download if RemoteModuleExtension.jar doesn't already exist or user specifies force overwrite
  if (nzchar(own_jar) && is_url(own_jar)) {
    anchors_url = own_jar # md5 must have same file name and .md5 suffix
    #md5_url = paste(own_jar, ".md5", sep="")
  } else {
    base_url <- paste("repo1.maven.org/maven2/de/viadee/xai/anchor/RemoteModuleExtension", version, sep = "/")
    web_filename <- paste0("RemoteModuleExtension","-",version,"-jar-with-dependencies.jar")
    anchors_url <- paste("https:/", base_url, web_filename, sep = "/") #https?
    # Get MD5 checksum
    #md5_url <- paste("http:/", base_url, "RemoteModuleExtenion.jar.md5", sep = "/") #maybe remove?
  }

  # security check
  #md5_file <- tempfile(fileext = ".md5")
  #download.file(md5_url, destfile = md5_file, mode = "w", cacheOK = FALSE, quiet = TRUE)
  #md5_check <- readLines(md5_file, n = 1L)
  #if (nchar(md5_check) != 32) stop("md5 malformed, must be 32 characters (see ", md5_url, ")")
  #unlink(md5_file)

  # Save to temporary file first to protect against incomplete downloads
  temp_file <- paste(dest_file, "tmp", sep = ".")
  cat("Performing one-time download of RemoteModuleExtension.jar from\n")
  cat("    ", anchors_url, "\n")
  cat("(This could take a few minutes, please be patient...)\n")
  download.file(url = anchors_url, destfile = temp_file, mode = "wb", cacheOK = FALSE, quiet = TRUE)

  # Apply sanity checks
  if(!file.exists(temp_file))
    stop("Error: Transfer failed. Please download ", anchors_url, " and place RemoteModuleExtension.jar in ", dest_folder)

  #md5_temp_file = md5sum(temp_file)
  #md5_temp_file_as_char = as.character(md5_temp_file)
  #if(md5_temp_file_as_char != md5_check) {
  #  cat("Error: Expected MD5: ", md5_check, "\n")
  #  cat("Error: Actual MD5  : ", md5_temp_file_as_char, "\n")
  #  stop("Error: MD5 checksum of ", temp_file, " does not match ", md5_check)
  #}

  # Move good file into final position
  file.rename(temp_file, dest_file)
  return(dest_file[file.exists(dest_file)])

}
