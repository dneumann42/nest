#ifndef NEST_WAYLAND_HEADLESS_SHIM_H
#define NEST_WAYLAND_HEADLESS_SHIM_H

#include <stdint.h>

struct nest_wl_client;

enum nest_wl_event_kind {
  NEST_WL_NONE = 0,
  NEST_WL_OUTPUT_ADDED,
  NEST_WL_OUTPUT_REMOVED,
  NEST_WL_TOPLEVEL_CHANGED,
  NEST_WL_TOPLEVEL_CLOSED,
  NEST_WL_OVERLAY_CONFIGURED,
  NEST_WL_FRAME,
  NEST_WL_POINTER_ENTER,
  NEST_WL_POINTER_LEAVE,
  NEST_WL_POINTER_MOTION,
  NEST_WL_POINTER_BUTTON,
  NEST_WL_CAPTURE_READY,
  NEST_WL_CAPTURE_FAILED
};

struct nest_wl_event {
  uint32_t kind, object, serial, time, detail, state;
  double x, y;
};

struct nest_wl_output_info {
  uint32_t id;
  int32_t x, y, width, height, scale;
  char name[128];
};

struct nest_wl_toplevel_info {
  uint32_t id, closed;
  char identifier[40], title[256], app_id[256];
};

struct nest_wl_capture_info {
  uint32_t width, height, format, generation, ready;
};

struct nest_wl_client *nest_wl_connect(const char *display_name);
void nest_wl_disconnect(struct nest_wl_client *client);
int nest_wl_dispatch(struct nest_wl_client *client, int timeout_ms);
int nest_wl_flush(struct nest_wl_client *client);
int nest_wl_next_event(struct nest_wl_client *client, struct nest_wl_event *event);
const char *nest_wl_last_error(struct nest_wl_client *client);

uint32_t nest_wl_output_count(struct nest_wl_client *client);
int nest_wl_output_info(struct nest_wl_client *client, uint32_t index,
                        struct nest_wl_output_info *info);
uint32_t nest_wl_toplevel_count(struct nest_wl_client *client);
int nest_wl_toplevel_info(struct nest_wl_client *client, uint32_t index,
                          struct nest_wl_toplevel_info *info);

uint32_t nest_wl_create_overlay(struct nest_wl_client *client,
                                uint32_t output_id, const char *name);
void nest_wl_destroy_overlay(struct nest_wl_client *client, uint32_t overlay_id);
void nest_wl_overlay_set_pointer(struct nest_wl_client *client,
                                 uint32_t overlay_id, int enabled);
void nest_wl_overlay_request_frame(struct nest_wl_client *client,
                                   uint32_t overlay_id);
int nest_wl_overlay_begin(struct nest_wl_client *client, uint32_t overlay_id);
void nest_wl_overlay_draw(struct nest_wl_client *client, uint32_t overlay_id,
                          uint32_t capture_id, float x, float y,
                          float width, float height, float opacity);
void nest_wl_overlay_end(struct nest_wl_client *client, uint32_t overlay_id);

uint32_t nest_wl_create_capture(struct nest_wl_client *client,
                                uint32_t toplevel_id);
void nest_wl_destroy_capture(struct nest_wl_client *client, uint32_t capture_id);
int nest_wl_capture_frame(struct nest_wl_client *client, uint32_t capture_id);
int nest_wl_capture_info(struct nest_wl_client *client, uint32_t capture_id,
                         struct nest_wl_capture_info *info);

#endif
