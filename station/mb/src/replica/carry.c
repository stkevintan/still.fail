// What the gathering and placing of a retired station's files (carry.mbt) ask of the system that the shell
// (client/shell) does not give: a file written a line at a time (a session's list, what a placing made), a file's
// times set as Node's utimesSync sets them, how many names a file has (lstat's nlink), a hard link that says why it
// could not be made, and whether what did not open was refused (EACCES, EPERM) rather than gone. Each path is UTF-8,
// ended by a NUL.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

#ifdef _WIN32
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>

static wchar_t *wide(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  if (n <= 0) return NULL;
  wchar_t *w = malloc(sizeof(wchar_t) * n);
  if (w != NULL) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
  return w;
}

static HANDLE opened(const char *path, DWORD access) {
  wchar_t *w = wide(path);
  if (w == NULL) return INVALID_HANDLE_VALUE;
  HANDLE h = CreateFileW(w, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  free(w);
  return h;
}
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <dirent.h>
#endif

/// `path` opened for writing (made where it is not): appended to with `append`, else emptied first. Its descriptor, or
/// -1.
int sfc_open(moonbit_bytes_t path, int append) {
#ifdef _WIN32
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return -1;
  int fd = _wopen(w, _O_WRONLY | _O_CREAT | _O_BINARY | (append ? _O_APPEND : _O_TRUNC), _S_IREAD | _S_IWRITE);
  free(w);
  return fd;
#else
  return open((const char *)path, O_WRONLY | O_CREAT | O_CLOEXEC | (append ? O_APPEND : O_TRUNC), 0666);
#endif
}

/// All of `data` written to `fd`: 0, or -1 where it could not be.
int sfc_write(int fd, moonbit_bytes_t data) {
  size_t len = Moonbit_array_length(data);
  size_t done = 0;
  while (done < len) {
#ifdef _WIN32
    int n = _write(fd, (const char *)data + done, (unsigned)(len - done));
#else
    ssize_t n = write(fd, (const char *)data + done, len - done);
    if (n < 0 && errno == EINTR) continue;
#endif
    if (n <= 0) return -1;
    done += (size_t)n;
  }
  return 0;
}

int sfc_close(int fd) {
#ifdef _WIN32
  return _close(fd);
#else
  return close(fd);
#endif
}

/// `path`'s access and modification times set to `secs` (seconds since 1970) as Node's utimesSync(path, secs, secs)
/// sets them (libuv 1.53's uv__fs_to_timespec, to the nanosecond the double gives): 0, or -1.
int sfc_utimes(moonbit_bytes_t path, double secs) {
#ifdef _WIN32
  // (libuv's uv__fs_utime_w: 100 ns since 1601)
  HANDLE h = opened((const char *)path, FILE_WRITE_ATTRIBUTES);
  if (h == INVALID_HANDLE_VALUE) return -1;
  int64_t ticks = (int64_t)(secs * 10000000.0) + 116444736000000000LL;
  FILETIME t;
  t.dwLowDateTime = (DWORD)(ticks & 0xFFFFFFFF);
  t.dwHighDateTime = (DWORD)(ticks >> 32);
  BOOL ok = SetFileTime(h, NULL, &t, &t);
  CloseHandle(h);
  return ok ? 0 : -1;
#else
  struct timespec ts[2];
  ts[0].tv_sec = (time_t)secs;
  ts[0].tv_nsec = (long)((secs - (double)ts[0].tv_sec) * 1e9);
  if (ts[0].tv_nsec < 0) {
    ts[0].tv_nsec += 1000000000L;
    ts[0].tv_sec -= 1;
  }
  ts[1] = ts[0];
  return utimensat(AT_FDCWD, (const char *)path, ts, 0) == 0 ? 0 : -1;
#endif
}

/// How many names the file at `path` has (lstat's nlink, a link itself not followed); -1 where it cannot be told.
int sfc_nlink(moonbit_bytes_t path) {
#ifdef _WIN32
  HANDLE h = opened((const char *)path, FILE_READ_ATTRIBUTES);
  if (h == INVALID_HANDLE_VALUE) return -1;
  BY_HANDLE_FILE_INFORMATION info;
  BOOL ok = GetFileInformationByHandle(h, &info);
  CloseHandle(h);
  return ok ? (int)info.nNumberOfLinks : -1;
#else
  struct stat st;
  if (lstat((const char *)path, &st) != 0) return -1;
  return (int)st.st_nlink;
#endif
}

/// A hard link `to` of `from`: 0 made; 1 where the disk makes none there (EXDEV, EPERM, ENOTSUP, EMLINK, ENOSYS: what
/// carry-reference.ts's putFile copied instead); 2 any other failure (`to` there already, `from` gone).
int sfc_link(moonbit_bytes_t from, moonbit_bytes_t to) {
#ifdef _WIN32
  wchar_t *f = wide((const char *)from);
  wchar_t *t = wide((const char *)to);
  BOOL ok = f != NULL && t != NULL && CreateHardLinkW(t, f, NULL);
  DWORD e = ok ? 0 : GetLastError();
  free(f);
  free(t);
  if (ok) return 0;
  return e == ERROR_NOT_SAME_DEVICE || e == ERROR_ACCESS_DENIED || e == ERROR_NOT_SUPPORTED || e == ERROR_TOO_MANY_LINKS ||
                 e == ERROR_INVALID_FUNCTION
             ? 1
             : 2;
#else
  if (link((const char *)from, (const char *)to) == 0) return 0;
  int e = errno;
  return e == EXDEV || e == EPERM || e == ENOTSUP || e == EMLINK || e == ENOSYS
#ifdef EOPNOTSUPP
                 || e == EOPNOTSUPP
#endif
             ? 1
             : 2;
#endif
}

/// Whether `path` (a directory with `dir`) is refused to this process as it is opened to be read (EACCES, EPERM), not
/// gone or read: what carry-reference.ts's gathering counted as unreadable.
int sfc_denied(moonbit_bytes_t path, int dir) {
#ifdef _WIN32
  (void)dir;
  HANDLE h = opened((const char *)path, GENERIC_READ);
  if (h != INVALID_HANDLE_VALUE) {
    CloseHandle(h);
    return 0;
  }
  return GetLastError() == ERROR_ACCESS_DENIED ? 1 : 0;
#else
  if (dir) {
    DIR *d = opendir((const char *)path);
    if (d != NULL) {
      closedir(d);
      return 0;
    }
  } else {
    int fd = open((const char *)path, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
      close(fd);
      return 0;
    }
  }
  return errno == EACCES || errno == EPERM ? 1 : 0;
#endif
}

/// Whether `path` is confirmed absent (ENOENT / ENOTDIR on POSIX; FILE_NOT_FOUND / PATH_NOT_FOUND / INVALID_NAME on
/// Windows) rather than unreadable (EACCES / EIO / other). `follow`: stat vs lstat.
int sfc_missing(moonbit_bytes_t path, int follow) {
#ifdef _WIN32
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return 0;
  DWORD attr = GetFileAttributesW(w);
  if (attr == INVALID_FILE_ATTRIBUTES) {
    DWORD e = GetLastError();
    free(w);
    return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME) ? 1 : 0;
  }
  if (follow && (attr & FILE_ATTRIBUTE_REPARSE_POINT)) {
    HANDLE h = CreateFileW(w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                           FILE_FLAG_BACKUP_SEMANTICS, NULL);
    DWORD e = h == INVALID_HANDLE_VALUE ? GetLastError() : 0;
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    free(w);
    if (h != INVALID_HANDLE_VALUE) return 0;
    return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME) ? 1 : 0;
  }
  free(w);
  return 0;
#else
  struct stat st;
  int rc = follow ? stat((const char *)path, &st) : lstat((const char *)path, &st);
  if (rc == 0) return 0;
  return (errno == ENOENT || errno == ENOTDIR) ? 1 : 0;
#endif
}

/// Whether directory `path` is confirmed absent or not a directory (ENOENT / ENOTDIR) when opened for listing, rather
/// than unreadable (EACCES / EIO / other).
int sfc_dir_missing(moonbit_bytes_t path) {
#ifdef _WIN32
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return 0;
  DWORD attr = GetFileAttributesW(w);
  free(w);
  if (attr != INVALID_FILE_ATTRIBUTES) return (attr & FILE_ATTRIBUTE_DIRECTORY) ? 0 : 1;
  DWORD e = GetLastError();
  return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME) ? 1 : 0;
#else
  DIR *d = opendir((const char *)path);
  if (d != NULL) {
    closedir(d);
    return 0;
  }
  return (errno == ENOENT || errno == ENOTDIR) ? 1 : 0;
#endif
}

/// Lightweight check whether directory `path` can be opened for listing (without reading/sorting entries):
/// returns 1 if readable OR confirmed missing/not-a-dir (ENOENT / ENOTDIR), 0 if unreadable (EACCES / EIO / other).
int sfc_dir_readable(moonbit_bytes_t path) {
#ifdef _WIN32
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return 0;
  HANDLE h = CreateFileW(w, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  DWORD e = h == INVALID_HANDLE_VALUE ? GetLastError() : 0;
  if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
  free(w);
  if (h != INVALID_HANDLE_VALUE) return 1;
  return (e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND || e == ERROR_INVALID_NAME || e == ERROR_DIRECTORY) ? 1 : 0;
#else
  DIR *d = opendir((const char *)path);
  if (d != NULL) {
    closedir(d);
    return 1;
  }
  return (errno == ENOENT || errno == ENOTDIR) ? 1 : 0;
#endif
}

/// Whether `path` is a regular file, links followed: what the shell's `fs.stat` says as "file" (Rust's
/// `fs::metadata(path).is_file()`, Node's `statSync(path).isFile()`), asked without a message to the shell, for a
/// replica's `sources` that asks it of every file a place lacks. 1 a file, 0 not one, -1 not known here: on Windows a
/// path of MAX_PATH or more, which the shell asks in its verbatim form (`\\?\`) and this does not.
int sfc_is_file(moonbit_bytes_t path) {
#ifdef _WIN32
  int n = MultiByteToWideChar(CP_UTF8, 0, (const char *)path, -1, NULL, 0);
  if (n <= 0 || n >= MAX_PATH) return -1;
  wchar_t *w = wide((const char *)path);
  if (w == NULL) return -1;
  DWORD attr = GetFileAttributesW(w);
  if (attr == INVALID_FILE_ATTRIBUTES) {
    DWORD e = GetLastError();
    free(w);
    return e == ERROR_FILENAME_EXCED_RANGE ? -1 : 0;
  }
  if ((attr & FILE_ATTRIBUTE_REPARSE_POINT) == 0) {
    free(w);
    return (attr & FILE_ATTRIBUTE_DIRECTORY) == 0 ? 1 : 0;
  }
  HANDLE h = CreateFileW(w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) return 0;
  BY_HANDLE_FILE_INFORMATION info;
  int ok = GetFileType(h) == FILE_TYPE_DISK && GetFileInformationByHandle(h, &info) &&
           (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
  CloseHandle(h);
  return ok ? 1 : 0;
#else
  struct stat st;
  return (stat((const char *)path, &st) == 0 && S_ISREG(st.st_mode)) ? 1 : 0;
#endif
}
