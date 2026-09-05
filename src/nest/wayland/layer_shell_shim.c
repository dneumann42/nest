#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <wayland-client.h>

#include "wlr-layer-shell-unstable-v1-client-protocol.h"

struct nest_layer_shell_state {
  struct wl_display *display;
  struct wl_surface *surface;
  struct zwlr_layer_shell_v1 *layer_shell;
  struct zwlr_layer_surface_v1 *layer_surface;
  uint32_t configured;
  uint32_t closed;
  uint32_t width;
  uint32_t height;
  uint32_t size_pending;
};

static struct nest_layer_shell_state global_state;

static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface,
                            uint32_t version) {
  struct nest_layer_shell_state *state = data;
  if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
    uint32_t bind_version = version < 5 ? version : 5;
    state->layer_shell = wl_registry_bind(
        registry, name, &zwlr_layer_shell_v1_interface, bind_version);
  }
}

static void registry_global_remove(void *data, struct wl_registry *registry,
                                   uint32_t name) {
  (void)data;
  (void)registry;
  (void)name;
}

static const struct wl_registry_listener registry_listener = {
    registry_global,
    registry_global_remove,
};

static void layer_surface_configure(
    void *data, struct zwlr_layer_surface_v1 *surface, uint32_t serial,
    uint32_t width, uint32_t height) {
  struct nest_layer_shell_state *state = data;
  state->configured = 1;
  state->width = width;
  state->height = height;
  state->size_pending = 1;
  zwlr_layer_surface_v1_ack_configure(surface, serial);
}

static void layer_surface_closed(void *data,
                                 struct zwlr_layer_surface_v1 *surface) {
  struct nest_layer_shell_state *state = data;
  (void)surface;
  state->closed = 1;
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
    layer_surface_configure,
    layer_surface_closed,
};

int nest_wayland_layer_shell_configure(
    void *display_ptr, void *surface_ptr, uint32_t width, uint32_t height,
    uint32_t layer, uint32_t anchor, int32_t exclusive_zone, int32_t margin_top,
    int32_t margin_right, int32_t margin_bottom, int32_t margin_left,
    uint32_t keyboard_interactivity, const char *layer_namespace,
    uint32_t *configured_width, uint32_t *configured_height) {
  struct wl_display *display = display_ptr;
  struct wl_surface *surface = surface_ptr;
  struct wl_registry *registry = NULL;
  struct nest_layer_shell_state *state = &global_state;

  memset(state, 0, sizeof(*state));

  if (display == NULL || surface == NULL) {
    return -1;
  }
  state->display = display;
  state->surface = surface;

  registry = wl_display_get_registry(display);
  if (registry == NULL) {
    return -2;
  }

  wl_registry_add_listener(registry, &registry_listener, state);
  wl_display_roundtrip(display);

  if (state->layer_shell == NULL) {
    wl_registry_destroy(registry);
    return -3;
  }

  state->layer_surface = zwlr_layer_shell_v1_get_layer_surface(
      state->layer_shell, surface, NULL, layer, layer_namespace);
  if (state->layer_surface == NULL) {
    zwlr_layer_shell_v1_destroy(state->layer_shell);
    wl_registry_destroy(registry);
    return -4;
  }

  zwlr_layer_surface_v1_add_listener(state->layer_surface,
                                     &layer_surface_listener, state);
  zwlr_layer_surface_v1_set_size(state->layer_surface, width, height);
  zwlr_layer_surface_v1_set_anchor(state->layer_surface, anchor);
  zwlr_layer_surface_v1_set_exclusive_zone(state->layer_surface,
                                           exclusive_zone);
  zwlr_layer_surface_v1_set_margin(state->layer_surface, margin_top,
                                   margin_right, margin_bottom, margin_left);
  zwlr_layer_surface_v1_set_keyboard_interactivity(
      state->layer_surface, keyboard_interactivity);

  wl_surface_commit(surface);

  while (!state->configured && !state->closed) {
    if (wl_display_roundtrip(display) < 0) {
      break;
    }
  }

  if (configured_width != NULL) {
    *configured_width = state->width;
  }
  if (configured_height != NULL) {
    *configured_height = state->height;
  }
  /* The first configure has already been returned to the caller above. */
  state->size_pending = 0;
  
  wl_registry_destroy(registry);
  return state->configured ? 0 : -5;
}

int nest_wayland_layer_shell_take_configured_size(uint32_t *width,
                                                  uint32_t *height) {
  struct nest_layer_shell_state *state = &global_state;

  if (!state->size_pending) {
    return 0;
  }
  state->size_pending = 0;
  if (width != NULL) {
    *width = state->width;
  }
  if (height != NULL) {
    *height = state->height;
  }
  return 1;
}

void nest_wayland_layer_shell_destroy(void) {
  struct nest_layer_shell_state *state = &global_state;

  if (state->layer_surface != NULL) {
    zwlr_layer_surface_v1_destroy(state->layer_surface);
    state->layer_surface = NULL;
  }
  if (state->layer_shell != NULL) {
    zwlr_layer_shell_v1_destroy(state->layer_shell);
    state->layer_shell = NULL;
  }
  if (state->display != NULL) {
    wl_display_flush(state->display);
  }

  memset(state, 0, sizeof(*state));
}

void nest_wayland_layer_shell_set_margin(int32_t top, int32_t right,
                                         int32_t bottom, int32_t left) {
  struct nest_layer_shell_state *state = &global_state;
  if (state->layer_surface == NULL || state->display == NULL) {
    return;
  }
  zwlr_layer_surface_v1_set_margin(state->layer_surface, top, right, bottom,
                                   left);
  wl_surface_commit(state->surface);
  wl_display_flush(state->display);
}
