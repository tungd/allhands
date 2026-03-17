#if defined(__linux__) && !defined(__GLIBC__)

#define _GNU_SOURCE
#define _LARGEFILE64_SOURCE

#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef open64
#undef open64
#endif
#ifdef stat64
#undef stat64
#endif
#ifdef lstat64
#undef lstat64
#endif
#ifdef fstat64
#undef fstat64
#endif
#ifdef lseek64
#undef lseek64
#endif
#ifdef truncate64
#undef truncate64
#endif
#ifdef ftruncate64
#undef ftruncate64
#endif
#ifdef pwrite64
#undef pwrite64
#endif
#ifdef mmap64
#undef mmap64
#endif
#ifdef fcntl64
#undef fcntl64
#endif
#ifdef readdir64
#undef readdir64
#endif

int open64(const char *path, int flags, ...)
{
  mode_t mode = 0;

  if ((flags & O_CREAT) != 0) {
    va_list args;
    va_start(args, flags);
    mode = va_arg(args, mode_t);
    va_end(args);
    return open(path, flags, mode);
  }

  return open(path, flags);
}

int stat64(const char *path, struct stat64 *buf)
{
  return stat(path, (struct stat *) buf);
}

int lstat64(const char *path, struct stat64 *buf)
{
  return lstat(path, (struct stat *) buf);
}

int fstat64(int fd, struct stat64 *buf)
{
  return fstat(fd, (struct stat *) buf);
}

off64_t lseek64(int fd, off64_t offset, int whence)
{
  return lseek(fd, offset, whence);
}

int truncate64(const char *path, off64_t length)
{
  return truncate(path, length);
}

int ftruncate64(int fd, off64_t length)
{
  return ftruncate(fd, length);
}

ssize_t pwrite64(int fd, const void *buf, size_t count, off64_t offset)
{
  return pwrite(fd, buf, count, offset);
}

void *mmap64(void *addr, size_t length, int prot, int flags, int fd, off64_t offset)
{
  return mmap(addr, length, prot, flags, fd, offset);
}

int fcntl64(int fd, int cmd, ...)
{
  va_list args;
  void *arg = NULL;

  va_start(args, cmd);
  arg = va_arg(args, void *);
  va_end(args);
  return fcntl(fd, cmd, arg);
}

struct dirent64 *readdir64(DIR *dirp)
{
  return (struct dirent64 *) readdir(dirp);
}

#endif
