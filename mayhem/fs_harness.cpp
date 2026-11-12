// libFuzzer harness for Haiku's userland file system emulation (src/tools/fs_shell).
//
// The input is a list of edits to one of three valid BFS disk images that are compiled into the
// binary (mayhem/fuzz_bfs/base/). Byte 0 picks the base image; after it, every 18 bytes are one
// record: a little-endian 16-bit slot and 16 bytes that overwrite the image at slot * 16 (modulo the
// image size). A trailing partial record is ignored, so every input is valid. Inputs stay a few
// hundred bytes on purpose: Mayhem cuts every seed to 8192 bytes, and BFS refuses an image shorter
// than the size in its superblock (Volume::Mount: diskSize < NumBlocks() << BlockShift()), so a
// whole 640 KiB - 1 MiB image can never be an input there.
//
// The edited image is mounted through the same fs_shell VFS that bfs_shell / fat_shell / ... use,
// then the tree is walked: stat, read files, symlinks, attributes, indices and a query. Which file
// system is fuzzed depends on the module linked in (modules[0]).
//
// fssh.cpp is included textually (main renamed) so the harness can reuse its static init_kernel().

#define main fssh_original_main
#include "fssh.cpp"
#undef main

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <string>

#ifndef FS_HARNESS_BASE_DIR
#error "FS_HARNESS_BASE_DIR must name the directory holding tree.img, many.img and small.img"
#endif

#define FS_INCBIN(symbol, file)                                                    \
	__asm__(".section .rodata\n.balign 16\n.globl " #symbol "\n" #symbol ":\n"     \
		".incbin \"" FS_HARNESS_BASE_DIR "/" file "\"\n"                           \
		".globl " #symbol "_end\n" #symbol "_end:\n.previous\n");                  \
	extern "C" const uint8_t symbol[], symbol##_end[]

FS_INCBIN(fs_base_tree, "tree.img");
FS_INCBIN(fs_base_many, "many.img");
FS_INCBIN(fs_base_small, "small.img");

#ifdef FS_HARNESS_CHECKFS
namespace FSShell {
fssh_status_t command_checkfs(int argc, const char* const* argv);
}
#endif

namespace {

const int kMaxDepth = 12;
const int kMaxNodes = 4000;
const fssh_off_t kMaxReadPerFile = 256 * 1024;

const size_t kRecordSize = 18;

struct BaseImage {
	const uint8_t* data;
	size_t size;
	size_t logOffset;	// the journal area is 512 KiB of zeros, so edits skip it
	size_t logSize;
};

BaseImage sBases[3];
int sImageFd = -1;
char sImagePath[4096];
int sNodes;

void
remove_image()
{
	unlink(sImagePath);
}


// Rebuilds the scratch image: the chosen base image, then the edits of data[1:].
bool
build_image(const uint8_t* data, size_t size)
{
	const BaseImage& base = sBases[data[0] % 3];
	if (ftruncate(sImageFd, 0) != 0
		|| pwrite(sImageFd, base.data, base.size, 0) != (ssize_t)base.size)
		return false;

	for (size_t pos = 1; pos + kRecordSize <= size; pos += kRecordSize) {
		size_t offset = ((size_t)(data[pos] | (data[pos + 1] << 8)) * 16) % (base.size - base.logSize);
		if (offset >= base.logOffset)
			offset += base.logSize;
		size_t length = 16;
		if (offset + length > base.size)
			length = base.size - offset;
		if (pwrite(sImageFd, data + pos + 2, length, offset) != (ssize_t)length)
			return false;
	}
	return true;
}


void
read_attributes(int fd)
{
	int attrDir = _kern_open_attr_dir(fd, NULL);
	if (attrDir < 0)
		return;

	char buffer[sizeof(fssh_dirent) + FSSH_B_FILE_NAME_LENGTH];
	fssh_dirent* entry = (fssh_dirent*)buffer;
	int count = 0;
	while (count++ < 256 && _kern_read_dir(attrDir, entry, sizeof(buffer), 1) == 1) {
		int attr = _kern_open_attr(fd, entry->d_name, FSSH_O_RDONLY);
		if (attr < 0)
			continue;
		char data[4096];
		_kern_read(attr, 0, data, sizeof(data));
		_kern_close(attr);
	}
	_kern_close(attrDir);
}

void
read_file(const std::string& path)
{
	int fd = _kern_open(-1, path.c_str(), FSSH_O_RDONLY, 0);
	if (fd < 0)
		return;

	static char data[64 * 1024];
	fssh_off_t pos = 0;
	while (pos < kMaxReadPerFile) {
		fssh_ssize_t got = _kern_read(fd, pos, data, sizeof(data));
		if (got <= 0)
			break;
		pos += got;
	}
	read_attributes(fd);
	_kern_close(fd);
}

void
walk(const std::string& path, int depth)
{
	int dir = _kern_open_dir(-1, path.c_str());
	if (dir < 0)
		return;

	read_attributes(dir);

	char buffer[sizeof(fssh_dirent) + FSSH_B_FILE_NAME_LENGTH];
	fssh_dirent* entry = (fssh_dirent*)buffer;
	while (sNodes < kMaxNodes && _kern_read_dir(dir, entry, sizeof(buffer), 1) == 1) {
		if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
			continue;
		sNodes++;

		std::string child = path + "/" + entry->d_name;
		struct fssh_stat st;
		if (_kern_read_stat(-1, child.c_str(), false, &st, sizeof(st)) != FSSH_B_OK)
			continue;

		if (FSSH_S_ISDIR(st.fssh_st_mode)) {
			if (depth < kMaxDepth)
				walk(child, depth + 1);
		} else if (FSSH_S_ISLNK(st.fssh_st_mode)) {
			char target[FSSH_B_PATH_NAME_LENGTH];
			fssh_size_t size = sizeof(target) - 1;
			_kern_read_link(-1, child.c_str(), target, &size);
		} else if (FSSH_S_ISREG(st.fssh_st_mode)) {
			read_file(child);
		}
	}
	_kern_close(dir);
}

void
list_indices_and_query(fssh_dev_t volume)
{
	int indexDir = _kern_open_index_dir(volume);
	if (indexDir >= 0) {
		char buffer[sizeof(fssh_dirent) + FSSH_B_FILE_NAME_LENGTH];
		fssh_dirent* entry = (fssh_dirent*)buffer;
		int count = 0;
		while (count++ < 64 && _kern_read_dir(indexDir, entry, sizeof(buffer), 1) == 1) {
			struct fssh_stat st;
			_kern_read_index_stat(volume, entry->d_name, &st);
		}
		_kern_close(indexDir);
	}

	static const char* const kQueries[] = {"name==\"*\"", "size>0"};
	for (size_t i = 0; i < sizeof(kQueries) / sizeof(kQueries[0]); i++) {
		int query = _kern_open_query(volume, kQueries[i], strlen(kQueries[i]), 0, -1, -1);
		if (query < 0)
			continue;
		char buffer[sizeof(fssh_dirent) + FSSH_B_FILE_NAME_LENGTH];
		fssh_dirent* entry = (fssh_dirent*)buffer;
		int count = 0;
		while (count++ < 256 && _kern_read_dir(query, entry, sizeof(buffer), 1) == 1) {
			char path[FSSH_B_PATH_NAME_LENGTH];
			_kern_entry_ref_to_path(volume, entry->d_pino, entry->d_name, path, sizeof(path));
		}
		_kern_close(query);
	}
}

}	// namespace


extern "C" int
LLVMFuzzerInitialize(int* argc, char*** argv)
{
	// dprintf() and the shell commands print to stdout
	static const char kDevNull[] = "/dev/null";
	if (!freopen(kDevNull, "w", stdout))
		abort();

	if (FSShell::init_kernel() != FSSH_B_OK)
		abort();

	const uint8_t* const images[3][2] = {{fs_base_tree, fs_base_tree_end},
		{fs_base_many, fs_base_many_end}, {fs_base_small, fs_base_small_end}};
	for (int i = 0; i < 3; i++) {
		BaseImage& base = sBases[i];
		base.data = images[i][0];
		base.size = images[i][1] - images[i][0];

		// disk_super_block (src/add-ons/kernel/file_systems/bfs/bfs.h) is at byte 512; its log_blocks
		// block_run {uint32 allocation_group; uint16 start; uint16 length} is at +88.
		uint16_t logStart, logLength;
		memcpy(&logStart, base.data + 512 + 92, sizeof(logStart));
		memcpy(&logLength, base.data + 512 + 94, sizeof(logLength));
		base.logOffset = (size_t)logStart << 10;
		base.logSize = (size_t)logLength << 10;
		if (base.logOffset + base.logSize >= base.size)
			abort();
	}

	const char* tmpdir = getenv("TMPDIR");
	snprintf(sImagePath, sizeof(sImagePath), "%s/fs-fuzz-XXXXXX",
		tmpdir != NULL && tmpdir[0] != '\0' ? tmpdir : "/tmp");
	sImageFd = mkstemp(sImagePath);
	if (sImageFd < 0) {
		fprintf(stderr, "fs_harness: cannot create %s: %s\n", sImagePath, strerror(errno));
		abort();
	}
	atexit(remove_image);

	// Each base image must mount, or no input would ever get past the mount.
	for (int i = 0; i < 3; i++) {
		const uint8_t selector = (uint8_t)i;
		if (!build_image(&selector, 1)) {
			fprintf(stderr, "fs_harness: cannot write %s: %s\n", sImagePath, strerror(errno));
			abort();
		}
		fssh_dev_t volume = _kern_mount(FSShell::kMountPoint, sImagePath, modules[0]->name, 0, NULL, 0);
		if (volume < 0) {
			fprintf(stderr, "fs_harness: base image %d does not mount from %s: %d\n", i, sImagePath,
				(int)volume);
			abort();
		}
		_kern_setcwd(-1, "/");
		if (_kern_unmount(FSShell::kMountPoint, 0) != FSSH_B_OK)
			abort();
	}
	return 0;
}


extern "C" int
LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
	if (size == 0)
		return -1;

	if (!build_image(data, size))
		abort();

	fssh_dev_t volume = _kern_mount(FSShell::kMountPoint, sImagePath, modules[0]->name, 0, NULL, 0);
	if (volume < 0)
		return -1;

	sNodes = 0;
	walk(FSShell::kMountPoint, 0);
	list_indices_and_query(volume);
#ifdef FS_HARNESS_CHECKFS
	{
		const char* const argv[] = {"checkfs", NULL};
		FSShell::command_checkfs(1, argv);
	}
#endif

	_kern_setcwd(-1, "/");
	if (_kern_unmount(FSShell::kMountPoint, 0) != FSSH_B_OK)
		abort();
	return 0;
}
