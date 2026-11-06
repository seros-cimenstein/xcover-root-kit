// touchgrab DEVICE: hold an exclusive grab (EVIOCGRAB) on an input device, so Android's input
// system receives none of its events. Input injected by agents (adb `input`, uiautomator) does
// not come from the device and still works. The grab ends when this process exits (the kernel
// releases it with the file descriptor), e.g. on SIGTERM.
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: %s /dev/input/eventN\n", argv[0]);
		return 2;
	}
	int fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	if (ioctl(fd, EVIOCGRAB, 1) < 0) {
		perror("EVIOCGRAB");
		return 1;
	}
	// Drain and drop the events; returns when the device goes away.
	struct input_event ev[64];
	while (read(fd, ev, sizeof ev) > 0) {
	}
	return 0;
}
