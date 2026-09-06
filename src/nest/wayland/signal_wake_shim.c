#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <unistd.h>

#include <wayland-client.h>

/* Signal handlers may safely write to a pipe. The layer-shell event loop
 * polls this descriptor beside Wayland's display descriptor. */
static int wake_pipe[2] = {-1, -1};
static volatile sig_atomic_t wake_started;
static volatile sig_atomic_t wake_pending;

int nest_signal_wake_start(void) {
  if (wake_started) return 0;
  if (pipe2(wake_pipe, O_CLOEXEC | O_NONBLOCK) != 0) return -1;
  wake_started = 1;
  return 0;
}

void nest_signal_wake_notify(void) {
  wake_pending = 1;
  if (!wake_started) return;
  uint8_t byte = 1;
  ssize_t ignored = write(wake_pipe[1], &byte, sizeof(byte));
  (void)ignored;
}

int nest_signal_wake_take_pending(void) {
  uint8_t bytes[64];
  if (!wake_pending) return 0;
  wake_pending = 0;
  while (read(wake_pipe[0], bytes, sizeof(bytes)) > 0) {
  }
  return 1;
}

int nest_wayland_wait_for_event_or_wake(void *display_ptr, int timeout_ms) {
  struct wl_display *display = display_ptr;
  if (wake_pending) return 1;
  if (!wake_started || display == NULL) return -1;
  struct pollfd descriptors[2] = {
      {.fd = wl_display_get_fd(display), .events = POLLIN},
      {.fd = wake_pipe[0], .events = POLLIN},
  };
  int result;
  do {
    result = poll(descriptors, 2, timeout_ms);
  } while (result < 0 && errno == EINTR && !wake_pending);
  if (wake_pending ||
      (result > 0 && (descriptors[1].revents & (POLLIN | POLLERR | POLLHUP))))
    return 1;
  if (result > 0 &&
      (descriptors[0].revents & (POLLIN | POLLERR | POLLHUP)))
    return 0;
  return -1;
}

void nest_signal_wake_stop(void) {
  if (!wake_started) return;
  wake_started = 0;
  wake_pending = 0;
  close(wake_pipe[0]);
  close(wake_pipe[1]);
  wake_pipe[0] = wake_pipe[1] = -1;
}
