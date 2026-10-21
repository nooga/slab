// C headers fy calls into, translated by the build (zig 0.17 dropped @cImport).
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <pthread.h>
#include <sys/mman.h>
#endif
