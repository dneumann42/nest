#define _GNU_SOURCE
#include "headless_shim.h"

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <wayland-client.h>
#include <wayland-egl.h>

#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "generated/ext-foreign-toplevel-list-v1-client-protocol.h"
#include "generated/ext-image-capture-source-v1-client-protocol.h"
#include "generated/ext-image-copy-capture-v1-client-protocol.h"
#include "generated/fractional-scale-v1-client-protocol.h"
#include "generated/viewporter-client-protocol.h"

#define MAX_OUTPUTS 16
#define MAX_TOPLEVELS 128
#define MAX_OVERLAYS 16
#define MAX_CAPTURES 128
#define EVENT_CAP 512

struct nest_wl_client;
struct output_rec { struct nest_wl_client *c; uint32_t id, global, removed; struct wl_output *wl; int32_t x,y,w,h,scale; char name[128]; };
struct top_rec { struct nest_wl_client *c; uint32_t id; struct ext_foreign_toplevel_handle_v1 *wl; int closed; char identifier[40], title[256], app_id[256]; };
struct overlay_rec { struct nest_wl_client *c; uint32_t id,preferred_scale; struct output_rec *out; struct wl_surface *surface; struct zwlr_layer_surface_v1 *layer; struct wp_fractional_scale_v1 *fractional; struct wp_viewport *viewport; struct wl_egl_window *egl_window; EGLSurface egl_surface; struct wl_callback *frame; int width,height,configured; };
struct capture_rec { struct nest_wl_client *c; uint32_t id; struct top_rec *top; struct ext_image_capture_source_v1 *source; struct ext_image_copy_capture_session_v1 *session; struct ext_image_copy_capture_frame_v1 *frame; struct wl_buffer *buffer; void *pixels; size_t bytes; int fd; uint32_t width,height,stride,format,buffer_width,buffer_height,buffer_format,generation; int constraints,ready,capturing; GLuint texture; };

struct nest_wl_client {
  struct wl_display *display; struct wl_registry *registry; struct wl_compositor *compositor;
  struct wl_shm *shm; struct wl_seat *seat; struct wl_pointer *pointer;
  struct zwlr_layer_shell_v1 *layer_shell;
  struct ext_foreign_toplevel_list_v1 *top_list;
  struct ext_foreign_toplevel_image_capture_source_manager_v1 *top_source;
  struct ext_image_copy_capture_manager_v1 *copy_manager;
  struct wp_fractional_scale_manager_v1 *fractional_manager;
  struct wp_viewporter *viewporter;
  struct output_rec outputs[MAX_OUTPUTS]; uint32_t noutputs, next_output;
  struct top_rec tops[MAX_TOPLEVELS]; uint32_t ntops, next_top;
  struct overlay_rec overlays[MAX_OVERLAYS]; uint32_t noverlays, next_overlay;
  struct capture_rec captures[MAX_CAPTURES]; uint32_t ncaptures, next_capture;
  struct nest_wl_event events[EVENT_CAP]; uint32_t event_read,event_write;
  EGLDisplay egl_display; EGLConfig egl_config; EGLContext egl_context;
  GLuint program, apos, auv, urect, uscreen, uopacity, utexture;
  uint32_t pointer_focus;
  char error[256];
};

static void copystr(char *dst, size_t size, const char *src) { if (!src) src=""; snprintf(dst,size,"%s",src); }
static void fail(struct nest_wl_client *c,const char *s) { copystr(c->error,sizeof(c->error),s); }
static void event(struct nest_wl_client *c,uint32_t kind,uint32_t object) { uint32_t n=(c->event_write+1)%EVENT_CAP; if(n==c->event_read)c->event_read=(c->event_read+1)%EVENT_CAP; memset(&c->events[c->event_write],0,sizeof(c->events[0])); c->events[c->event_write].kind=kind; c->events[c->event_write].object=object; c->event_write=n; }
static struct output_rec *output_by_id(struct nest_wl_client*c,uint32_t id){for(uint32_t i=0;i<c->noutputs;i++)if(c->outputs[i].id==id)return &c->outputs[i];return NULL;}
static struct top_rec *top_by_id(struct nest_wl_client*c,uint32_t id){for(uint32_t i=0;i<c->ntops;i++)if(c->tops[i].id==id)return &c->tops[i];return NULL;}
static struct overlay_rec *overlay_by_id(struct nest_wl_client*c,uint32_t id){for(uint32_t i=0;i<c->noverlays;i++)if(c->overlays[i].id==id)return &c->overlays[i];return NULL;}
static struct capture_rec *capture_by_id(struct nest_wl_client*c,uint32_t id){for(uint32_t i=0;i<c->ncaptures;i++)if(c->captures[i].id==id)return &c->captures[i];return NULL;}

static void out_geometry(void*d,struct wl_output*o,int32_t x,int32_t y,int32_t pw,int32_t ph,int32_t sub,const char*make,const char*model,int32_t trans){struct output_rec*r=d;(void)o;(void)pw;(void)ph;(void)sub;(void)make;(void)model;(void)trans;r->x=x;r->y=y;}
static void out_mode(void*d,struct wl_output*o,uint32_t flags,int32_t w,int32_t h,int32_t refresh){struct output_rec*r=d;(void)o;(void)refresh;if(flags&WL_OUTPUT_MODE_CURRENT){r->w=w;r->h=h;}}
static void out_done(void*d,struct wl_output*o){struct output_rec*r=d;(void)o;event(r->c,NEST_WL_OUTPUT_ADDED,r->id);}
static void out_scale(void*d,struct wl_output*o,int32_t scale){struct output_rec*r=d;(void)o;r->scale=scale>0?scale:1;}
static void out_name(void*d,struct wl_output*o,const char*name){struct output_rec*r=d;(void)o;copystr(r->name,sizeof(r->name),name);}
static void out_desc(void*d,struct wl_output*o,const char*desc){(void)d;(void)o;(void)desc;}
static const struct wl_output_listener output_listener={out_geometry,out_mode,out_done,out_scale,out_name,out_desc};

static void top_closed(void*d,struct ext_foreign_toplevel_handle_v1*h){struct top_rec*r=d;(void)h;r->closed=1;event(r->c,NEST_WL_TOPLEVEL_CLOSED,r->id);}
static void top_done(void*d,struct ext_foreign_toplevel_handle_v1*h){struct top_rec*r=d;(void)h;event(r->c,NEST_WL_TOPLEVEL_CHANGED,r->id);}
static void top_title(void*d,struct ext_foreign_toplevel_handle_v1*h,const char*s){struct top_rec*r=d;(void)h;copystr(r->title,sizeof(r->title),s);}
static void top_app(void*d,struct ext_foreign_toplevel_handle_v1*h,const char*s){struct top_rec*r=d;(void)h;copystr(r->app_id,sizeof(r->app_id),s);}
static void top_identifier(void*d,struct ext_foreign_toplevel_handle_v1*h,const char*s){struct top_rec*r=d;(void)h;copystr(r->identifier,sizeof(r->identifier),s);}
static const struct ext_foreign_toplevel_handle_v1_listener top_listener={top_closed,top_done,top_title,top_app,top_identifier};
static void list_top(void*d,struct ext_foreign_toplevel_list_v1*l,struct ext_foreign_toplevel_handle_v1*h){struct nest_wl_client*c=d;(void)l;if(c->ntops>=MAX_TOPLEVELS){ext_foreign_toplevel_handle_v1_destroy(h);return;}struct top_rec*r=&c->tops[c->ntops++];memset(r,0,sizeof(*r));r->c=c;r->id=++c->next_top;r->wl=h;ext_foreign_toplevel_handle_v1_add_listener(h,&top_listener,r);}
static void list_finished(void*d,struct ext_foreign_toplevel_list_v1*l){(void)d;(void)l;}
static const struct ext_foreign_toplevel_list_v1_listener list_listener={list_top,list_finished};

static void pointer_enter(void*d,struct wl_pointer*p,uint32_t serial,struct wl_surface*s,wl_fixed_t x,wl_fixed_t y){struct nest_wl_client*c=d;(void)p;for(uint32_t i=0;i<c->noverlays;i++)if(c->overlays[i].surface==s){c->pointer_focus=c->overlays[i].id;event(c,NEST_WL_POINTER_ENTER,c->overlays[i].id);struct nest_wl_event*e=&c->events[(c->event_write+EVENT_CAP-1)%EVENT_CAP];e->serial=serial;e->x=wl_fixed_to_double(x);e->y=wl_fixed_to_double(y);}}
static void pointer_leave(void*d,struct wl_pointer*p,uint32_t serial,struct wl_surface*s){struct nest_wl_client*c=d;(void)p;for(uint32_t i=0;i<c->noverlays;i++)if(c->overlays[i].surface==s){event(c,NEST_WL_POINTER_LEAVE,c->overlays[i].id);c->events[(c->event_write+EVENT_CAP-1)%EVENT_CAP].serial=serial;c->pointer_focus=0;}}
static void pointer_motion(void*d,struct wl_pointer*p,uint32_t time,wl_fixed_t x,wl_fixed_t y){struct nest_wl_client*c=d;(void)p;event(c,NEST_WL_POINTER_MOTION,c->pointer_focus);struct nest_wl_event*e=&c->events[(c->event_write+EVENT_CAP-1)%EVENT_CAP];e->time=time;e->x=wl_fixed_to_double(x);e->y=wl_fixed_to_double(y);}
static void pointer_button(void*d,struct wl_pointer*p,uint32_t serial,uint32_t time,uint32_t button,uint32_t state){struct nest_wl_client*c=d;(void)p;event(c,NEST_WL_POINTER_BUTTON,0);struct nest_wl_event*e=&c->events[(c->event_write+EVENT_CAP-1)%EVENT_CAP];e->serial=serial;e->time=time;e->detail=button;e->state=state;}
static void pointer_axis(void*d,struct wl_pointer*p,uint32_t time,uint32_t axis,wl_fixed_t value){(void)d;(void)p;(void)time;(void)axis;(void)value;}
static void pointer_frame(void*d,struct wl_pointer*p){(void)d;(void)p;} static void pointer_axis_source(void*d,struct wl_pointer*p,uint32_t s){(void)d;(void)p;(void)s;} static void pointer_axis_stop(void*d,struct wl_pointer*p,uint32_t t,uint32_t a){(void)d;(void)p;(void)t;(void)a;} static void pointer_axis_discrete(void*d,struct wl_pointer*p,uint32_t a,int32_t v){(void)d;(void)p;(void)a;(void)v;} static void pointer_axis_value120(void*d,struct wl_pointer*p,uint32_t a,int32_t v){(void)d;(void)p;(void)a;(void)v;} static void pointer_axis_relative_direction(void*d,struct wl_pointer*p,uint32_t a,uint32_t v){(void)d;(void)p;(void)a;(void)v;}
static const struct wl_pointer_listener pointer_listener={pointer_enter,pointer_leave,pointer_motion,pointer_button,pointer_axis,pointer_frame,pointer_axis_source,pointer_axis_stop,pointer_axis_discrete,pointer_axis_value120,pointer_axis_relative_direction};
static void seat_caps(void*d,struct wl_seat*s,uint32_t caps){struct nest_wl_client*c=d;if((caps&WL_SEAT_CAPABILITY_POINTER)&&!c->pointer){c->pointer=wl_seat_get_pointer(s);wl_pointer_add_listener(c->pointer,&pointer_listener,c);}else if(!(caps&WL_SEAT_CAPABILITY_POINTER)&&c->pointer){wl_pointer_destroy(c->pointer);c->pointer=NULL;}}
static void seat_name(void*d,struct wl_seat*s,const char*n){(void)d;(void)s;(void)n;} static const struct wl_seat_listener seat_listener={seat_caps,seat_name};

static void global(void*d,struct wl_registry*r,uint32_t name,const char*iface,uint32_t version){struct nest_wl_client*c=d;
#define BIND(field,type,maxv) c->field=wl_registry_bind(r,name,&type##_interface,version<(maxv)?version:(maxv))
 if(!strcmp(iface,wl_compositor_interface.name))BIND(compositor,wl_compositor,6);else if(!strcmp(iface,wl_shm_interface.name))BIND(shm,wl_shm,1);else if(!strcmp(iface,wl_seat_interface.name)){BIND(seat,wl_seat,9);wl_seat_add_listener(c->seat,&seat_listener,c);}else if(!strcmp(iface,zwlr_layer_shell_v1_interface.name))BIND(layer_shell,zwlr_layer_shell_v1,5);else if(!strcmp(iface,ext_foreign_toplevel_list_v1_interface.name)){BIND(top_list,ext_foreign_toplevel_list_v1,1);ext_foreign_toplevel_list_v1_add_listener(c->top_list,&list_listener,c);}else if(!strcmp(iface,ext_foreign_toplevel_image_capture_source_manager_v1_interface.name))BIND(top_source,ext_foreign_toplevel_image_capture_source_manager_v1,1);else if(!strcmp(iface,ext_image_copy_capture_manager_v1_interface.name))BIND(copy_manager,ext_image_copy_capture_manager_v1,1);else if(!strcmp(iface,wp_fractional_scale_manager_v1_interface.name))BIND(fractional_manager,wp_fractional_scale_manager_v1,1);else if(!strcmp(iface,wp_viewporter_interface.name))BIND(viewporter,wp_viewporter,1);else if(!strcmp(iface,wl_output_interface.name)&&c->noutputs<MAX_OUTPUTS){struct output_rec*o=&c->outputs[c->noutputs++];memset(o,0,sizeof(*o));o->c=c;o->id=++c->next_output;o->global=name;o->scale=1;o->wl=wl_registry_bind(r,name,&wl_output_interface,version<4?version:4);wl_output_add_listener(o->wl,&output_listener,o);}
#undef BIND
}
static void global_remove(void*d,struct wl_registry*r,uint32_t name){struct nest_wl_client*c=d;(void)r;for(uint32_t i=0;i<c->noutputs;i++)if(c->outputs[i].global==name){c->outputs[i].removed=1;event(c,NEST_WL_OUTPUT_REMOVED,c->outputs[i].id);break;}}
static const struct wl_registry_listener registry_listener={global,global_remove};

static GLuint shader(GLenum type,const char*src){GLuint s=glCreateShader(type);glShaderSource(s,1,&src,NULL);glCompileShader(s);return s;}
static int init_egl(struct nest_wl_client*c){c->egl_display=eglGetDisplay((EGLNativeDisplayType)c->display);if(c->egl_display==EGL_NO_DISPLAY||!eglInitialize(c->egl_display,NULL,NULL)){fail(c,"EGL initialization failed");return 0;}EGLint attrs[]={EGL_SURFACE_TYPE,EGL_WINDOW_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};EGLint n=0;if(!eglChooseConfig(c->egl_display,attrs,&c->egl_config,1,&n)||!n){fail(c,"no RGBA EGL config");return 0;}EGLint ctx[]={EGL_CONTEXT_CLIENT_VERSION,2,EGL_NONE};c->egl_context=eglCreateContext(c->egl_display,c->egl_config,EGL_NO_CONTEXT,ctx);return c->egl_context!=EGL_NO_CONTEXT;}
static void init_gl(struct nest_wl_client*c){if(c->program)return;const char*vs="attribute vec2 p;attribute vec2 uv;uniform vec4 rect;uniform vec2 screen;varying vec2 v;void main(){vec2 q=rect.xy+p*rect.zw;gl_Position=vec4(q.x/screen.x*2.0-1.0,1.0-q.y/screen.y*2.0,0,1);v=uv;}";const char*fs="precision mediump float;uniform sampler2D tex;uniform float opacity;varying vec2 v;void main(){gl_FragColor=texture2D(tex,v)*opacity;}";GLuint a=shader(GL_VERTEX_SHADER,vs),b=shader(GL_FRAGMENT_SHADER,fs);c->program=glCreateProgram();glAttachShader(c->program,a);glAttachShader(c->program,b);glLinkProgram(c->program);glDeleteShader(a);glDeleteShader(b);c->apos=glGetAttribLocation(c->program,"p");c->auv=glGetAttribLocation(c->program,"uv");c->urect=glGetUniformLocation(c->program,"rect");c->uscreen=glGetUniformLocation(c->program,"screen");c->uopacity=glGetUniformLocation(c->program,"opacity");c->utexture=glGetUniformLocation(c->program,"tex");}

static void resize_overlay(struct overlay_rec*o){if(!o->egl_window)return;double scale=o->preferred_scale?o->preferred_scale/120.0:o->out->scale;wl_egl_window_resize(o->egl_window,(int)ceil(o->width*scale),(int)ceil(o->height*scale),0,0);if(o->viewport)wp_viewport_set_destination(o->viewport,o->width,o->height);}
static void preferred_scale(void*d,struct wp_fractional_scale_v1*s,uint32_t scale){struct overlay_rec*o=d;(void)s;o->preferred_scale=scale;resize_overlay(o);}
static const struct wp_fractional_scale_v1_listener fractional_listener={preferred_scale};
static void layer_configure(void*d,struct zwlr_layer_surface_v1*l,uint32_t serial,uint32_t w,uint32_t h){struct overlay_rec*o=d;zwlr_layer_surface_v1_ack_configure(l,serial);o->width=w;o->height=h;o->configured=1;resize_overlay(o);event(o->c,NEST_WL_OVERLAY_CONFIGURED,o->id);}
static void layer_closed(void*d,struct zwlr_layer_surface_v1*l){struct overlay_rec*o=d;(void)l;o->configured=0;}
static const struct zwlr_layer_surface_v1_listener layer_listener={layer_configure,layer_closed};
static void frame_done(void*d,struct wl_callback*cb,uint32_t time){struct overlay_rec*o=d;wl_callback_destroy(cb);o->frame=NULL;event(o->c,NEST_WL_FRAME,o->id);o->c->events[(o->c->event_write+EVENT_CAP-1)%EVENT_CAP].time=time;}
static const struct wl_callback_listener frame_listener={frame_done};

static int make_shm(size_t bytes){int fd=memfd_create("nest-capture",MFD_CLOEXEC);if(fd<0)return -1;if(ftruncate(fd,(off_t)bytes)<0){close(fd);return -1;}return fd;}
static void session_size(void*d,struct ext_image_copy_capture_session_v1*s,uint32_t w,uint32_t h){struct capture_rec*c=d;(void)s;c->width=w;c->height=h;}
static void session_shm(void*d,struct ext_image_copy_capture_session_v1*s,uint32_t fmt){struct capture_rec*c=d;(void)s;if(!c->format&&(fmt==WL_SHM_FORMAT_ARGB8888||fmt==WL_SHM_FORMAT_XRGB8888))c->format=fmt;}
static void session_dmabuf_dev(void*d,struct ext_image_copy_capture_session_v1*s,struct wl_array*a){(void)d;(void)s;(void)a;} static void session_dmabuf_fmt(void*d,struct ext_image_copy_capture_session_v1*s,uint32_t f,struct wl_array*m){(void)d;(void)s;(void)f;(void)m;}
static void session_done(void*d,struct ext_image_copy_capture_session_v1*s){struct capture_rec*c=d;(void)s;c->constraints=1;}
static void session_stopped(void*d,struct ext_image_copy_capture_session_v1*s){struct capture_rec*c=d;(void)s;c->constraints=0;event(c->c,NEST_WL_CAPTURE_FAILED,c->id);}
static const struct ext_image_copy_capture_session_v1_listener session_listener={session_size,session_shm,session_dmabuf_dev,session_dmabuf_fmt,session_done,session_stopped};
static void capture_release_buffer(struct capture_rec*c){if(c->buffer)wl_buffer_destroy(c->buffer);c->buffer=NULL;if(c->pixels&&c->bytes)munmap(c->pixels,c->bytes);c->pixels=NULL;if(c->fd>=0)close(c->fd);c->fd=-1;c->bytes=0;}
static int capture_buffer(struct capture_rec*c){capture_release_buffer(c);if(!c->width||!c->height||!c->format)return 0;c->stride=c->width*4;c->bytes=(size_t)c->stride*c->height;c->fd=make_shm(c->bytes);if(c->fd<0)return 0;c->pixels=mmap(NULL,c->bytes,PROT_READ|PROT_WRITE,MAP_SHARED,c->fd,0);if(c->pixels==MAP_FAILED){c->pixels=NULL;capture_release_buffer(c);return 0;}struct wl_shm_pool*p=wl_shm_create_pool(c->c->shm,c->fd,c->bytes);c->buffer=wl_shm_pool_create_buffer(p,0,c->width,c->height,c->stride,c->format);wl_shm_pool_destroy(p);c->buffer_width=c->width;c->buffer_height=c->height;c->buffer_format=c->format;return c->buffer!=NULL;}
static void cap_transform(void*d,struct ext_image_copy_capture_frame_v1*f,uint32_t t){(void)d;(void)f;(void)t;} static void cap_damage(void*d,struct ext_image_copy_capture_frame_v1*f,int32_t x,int32_t y,int32_t w,int32_t h){(void)d;(void)f;(void)x;(void)y;(void)w;(void)h;} static void cap_time(void*d,struct ext_image_copy_capture_frame_v1*f,uint32_t hi,uint32_t lo,uint32_t n){(void)d;(void)f;(void)hi;(void)lo;(void)n;}
static void cap_ready(void*d,struct ext_image_copy_capture_frame_v1*f){struct capture_rec*c=d;ext_image_copy_capture_frame_v1_destroy(f);c->frame=NULL;c->capturing=0;c->ready=1;c->generation++;event(c->c,NEST_WL_CAPTURE_READY,c->id);}
static void cap_failed(void*d,struct ext_image_copy_capture_frame_v1*f,uint32_t reason){struct capture_rec*c=d;ext_image_copy_capture_frame_v1_destroy(f);c->frame=NULL;c->capturing=0;event(c->c,NEST_WL_CAPTURE_FAILED,c->id);c->c->events[(c->c->event_write+EVENT_CAP-1)%EVENT_CAP].detail=reason;}
static const struct ext_image_copy_capture_frame_v1_listener capture_listener={cap_transform,cap_damage,cap_time,cap_ready,cap_failed};

struct nest_wl_client *nest_wl_connect(const char*name){struct nest_wl_client*c=calloc(1,sizeof(*c));if(!c)return NULL;c->egl_display=EGL_NO_DISPLAY;c->egl_context=EGL_NO_CONTEXT;c->display=wl_display_connect(name);if(!c->display){free(c);return NULL;}c->registry=wl_display_get_registry(c->display);wl_registry_add_listener(c->registry,&registry_listener,c);if(wl_display_roundtrip(c->display)<0||wl_display_roundtrip(c->display)<0){nest_wl_disconnect(c);return NULL;}if(!c->compositor||!c->layer_shell){fail(c,"compositor lacks wlr-layer-shell");return c;}init_egl(c);return c;}
void nest_wl_disconnect(struct nest_wl_client*c){if(!c)return;for(uint32_t i=0;i<c->ncaptures;i++)if(c->captures[i].id)nest_wl_destroy_capture(c,c->captures[i].id);for(uint32_t i=0;i<c->noverlays;i++)if(c->overlays[i].id)nest_wl_destroy_overlay(c,c->overlays[i].id);for(uint32_t i=0;i<c->ntops;i++)if(c->tops[i].wl)ext_foreign_toplevel_handle_v1_destroy(c->tops[i].wl);for(uint32_t i=0;i<c->noutputs;i++)if(c->outputs[i].wl)wl_output_destroy(c->outputs[i].wl);if(c->pointer)wl_pointer_destroy(c->pointer);if(c->seat)wl_seat_destroy(c->seat);if(c->top_list)ext_foreign_toplevel_list_v1_destroy(c->top_list);if(c->top_source)ext_foreign_toplevel_image_capture_source_manager_v1_destroy(c->top_source);if(c->copy_manager)ext_image_copy_capture_manager_v1_destroy(c->copy_manager);if(c->fractional_manager)wp_fractional_scale_manager_v1_destroy(c->fractional_manager);if(c->viewporter)wp_viewporter_destroy(c->viewporter);if(c->layer_shell)zwlr_layer_shell_v1_destroy(c->layer_shell);if(c->shm)wl_shm_destroy(c->shm);if(c->compositor)wl_compositor_destroy(c->compositor);if(c->registry)wl_registry_destroy(c->registry);if(c->egl_context!=EGL_NO_CONTEXT)eglDestroyContext(c->egl_display,c->egl_context);if(c->egl_display!=EGL_NO_DISPLAY)eglTerminate(c->egl_display);if(c->display)wl_display_disconnect(c->display);free(c);}
int nest_wl_dispatch(struct nest_wl_client*c,int timeout){if(!c||!c->display)return -1;while(wl_display_prepare_read(c->display)!=0)if(wl_display_dispatch_pending(c->display)<0)return -1;wl_display_flush(c->display);struct pollfd p={wl_display_get_fd(c->display),POLLIN,0};int r=poll(&p,1,timeout);if(r>0&&(p.revents&POLLIN)){if(wl_display_read_events(c->display)<0)return -1;}else wl_display_cancel_read(c->display);if(r<0&&errno!=EINTR)return -1;return wl_display_dispatch_pending(c->display);}
int nest_wl_flush(struct nest_wl_client*c){return c?wl_display_flush(c->display):-1;} int nest_wl_next_event(struct nest_wl_client*c,struct nest_wl_event*e){if(!c||c->event_read==c->event_write)return 0;*e=c->events[c->event_read];c->event_read=(c->event_read+1)%EVENT_CAP;return 1;} const char*nest_wl_last_error(struct nest_wl_client*c){return c?c->error:"connection failed";}
uint32_t nest_wl_output_count(struct nest_wl_client*c){return c?c->noutputs:0;} int nest_wl_output_info(struct nest_wl_client*c,uint32_t i,struct nest_wl_output_info*x){if(!c||i>=c->noutputs||!x||c->outputs[i].removed)return 0;struct output_rec*o=&c->outputs[i];memset(x,0,sizeof(*x));x->id=o->id;x->x=o->x;x->y=o->y;x->scale=o->scale;x->width=o->w/o->scale;x->height=o->h/o->scale;copystr(x->name,sizeof(x->name),o->name);return 1;}
uint32_t nest_wl_toplevel_count(struct nest_wl_client*c){return c?c->ntops:0;} int nest_wl_toplevel_info(struct nest_wl_client*c,uint32_t i,struct nest_wl_toplevel_info*x){if(!c||i>=c->ntops||!x)return 0;struct top_rec*t=&c->tops[i];memset(x,0,sizeof(*x));x->id=t->id;x->closed=t->closed;copystr(x->identifier,sizeof(x->identifier),t->identifier);copystr(x->title,sizeof(x->title),t->title);copystr(x->app_id,sizeof(x->app_id),t->app_id);return 1;}

uint32_t nest_wl_create_overlay(struct nest_wl_client*c,uint32_t oid,const char*name){if(!c||!c->compositor||!c->layer_shell||c->egl_context==EGL_NO_CONTEXT)return 0;struct output_rec*out=output_by_id(c,oid);if(!out)return 0;struct overlay_rec*o=NULL;for(uint32_t i=0;i<c->noverlays;i++)if(!c->overlays[i].id){o=&c->overlays[i];break;}if(!o){if(c->noverlays>=MAX_OVERLAYS)return 0;o=&c->overlays[c->noverlays++];}memset(o,0,sizeof(*o));o->c=c;o->id=++c->next_overlay;o->out=out;o->width=out->w/out->scale;o->height=out->h/out->scale;o->surface=wl_compositor_create_surface(c->compositor);if(c->fractional_manager&&c->viewporter){o->fractional=wp_fractional_scale_manager_v1_get_fractional_scale(c->fractional_manager,o->surface);wp_fractional_scale_v1_add_listener(o->fractional,&fractional_listener,o);o->viewport=wp_viewporter_get_viewport(c->viewporter,o->surface);wl_surface_set_buffer_scale(o->surface,1);}else wl_surface_set_buffer_scale(o->surface,out->scale);o->layer=zwlr_layer_shell_v1_get_layer_surface(c->layer_shell,o->surface,out->wl,ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,name?name:"nest");zwlr_layer_surface_v1_add_listener(o->layer,&layer_listener,o);zwlr_layer_surface_v1_set_size(o->layer,0,0);zwlr_layer_surface_v1_set_anchor(o->layer,15);zwlr_layer_surface_v1_set_exclusive_zone(o->layer,0);zwlr_layer_surface_v1_set_keyboard_interactivity(o->layer,ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);nest_wl_overlay_set_pointer(c,o->id,0);wl_surface_commit(o->surface);wl_display_roundtrip(c->display);double scale=o->preferred_scale?o->preferred_scale/120.0:out->scale;o->egl_window=wl_egl_window_create(o->surface,(int)ceil(o->width*scale),(int)ceil(o->height*scale));if(o->viewport)wp_viewport_set_destination(o->viewport,o->width,o->height);o->egl_surface=eglCreateWindowSurface(c->egl_display,c->egl_config,(EGLNativeWindowType)o->egl_window,NULL);return o->id;}
void nest_wl_destroy_overlay(struct nest_wl_client*c,uint32_t id){struct overlay_rec*o=overlay_by_id(c,id);if(!o)return;if(o->frame)wl_callback_destroy(o->frame);if(o->egl_surface)eglDestroySurface(c->egl_display,o->egl_surface);if(o->egl_window)wl_egl_window_destroy(o->egl_window);if(o->fractional)wp_fractional_scale_v1_destroy(o->fractional);if(o->viewport)wp_viewport_destroy(o->viewport);if(o->layer)zwlr_layer_surface_v1_destroy(o->layer);if(o->surface)wl_surface_destroy(o->surface);memset(o,0,sizeof(*o));}
void nest_wl_overlay_set_pointer(struct nest_wl_client*c,uint32_t id,int enabled){struct overlay_rec*o=overlay_by_id(c,id);if(!o)return;struct wl_region*r=wl_compositor_create_region(c->compositor);if(enabled)wl_region_add(r,0,0,INT32_MAX,INT32_MAX);wl_surface_set_input_region(o->surface,r);wl_region_destroy(r);wl_surface_commit(o->surface);}
void nest_wl_overlay_request_frame(struct nest_wl_client*c,uint32_t id){struct overlay_rec*o=overlay_by_id(c,id);if(o&&!o->frame){o->frame=wl_surface_frame(o->surface);wl_callback_add_listener(o->frame,&frame_listener,o);wl_surface_commit(o->surface);wl_display_flush(c->display);}}
int nest_wl_overlay_begin(struct nest_wl_client*c,uint32_t id){struct overlay_rec*o=overlay_by_id(c,id);if(!o||!o->configured||o->egl_surface==EGL_NO_SURFACE)return 0;eglMakeCurrent(c->egl_display,o->egl_surface,o->egl_surface,c->egl_context);init_gl(c);double scale=o->preferred_scale?o->preferred_scale/120.0:o->out->scale;glViewport(0,0,(int)ceil(o->width*scale),(int)ceil(o->height*scale));glClearColor(0,0,0,0);glClear(GL_COLOR_BUFFER_BIT);glEnable(GL_BLEND);glBlendFunc(GL_ONE,GL_ONE_MINUS_SRC_ALPHA);glUseProgram(c->program);glUniform2f(c->uscreen,o->width,o->height);return 1;}
void nest_wl_overlay_draw(struct nest_wl_client*c,uint32_t oid,uint32_t cid,float x,float y,float w,float h,float opacity){struct overlay_rec*o=overlay_by_id(c,oid);struct capture_rec*r=capture_by_id(c,cid);if(!o||!r||!r->ready)return;if(!r->texture)glGenTextures(1,&r->texture);glBindTexture(GL_TEXTURE_2D,r->texture);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);if(r->ready==1){GLenum fmt=r->format==WL_SHM_FORMAT_ARGB8888?GL_BGRA_EXT:GL_BGRA_EXT;glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,r->width,r->height,0,fmt,GL_UNSIGNED_BYTE,r->pixels);r->ready=2;}const GLfloat verts[]={0,0,0,0, 1,0,1,0, 0,1,0,1, 1,1,1,1};glUniform4f(c->urect,x,y,w,h);glUniform1f(c->uopacity,opacity);glUniform1i(c->utexture,0);glVertexAttribPointer(c->apos,2,GL_FLOAT,0,4*sizeof(GLfloat),verts);glVertexAttribPointer(c->auv,2,GL_FLOAT,0,4*sizeof(GLfloat),verts+2);glEnableVertexAttribArray(c->apos);glEnableVertexAttribArray(c->auv);glDrawArrays(GL_TRIANGLE_STRIP,0,4);}
void nest_wl_overlay_end(struct nest_wl_client*c,uint32_t id){struct overlay_rec*o=overlay_by_id(c,id);if(o)eglSwapBuffers(c->egl_display,o->egl_surface);}

uint32_t nest_wl_create_capture(struct nest_wl_client*c,uint32_t tid){if(!c||!c->top_source||!c->copy_manager||!c->shm)return 0;struct top_rec*t=top_by_id(c,tid);if(!t||t->closed)return 0;struct capture_rec*r=NULL;for(uint32_t i=0;i<c->ncaptures;i++)if(!c->captures[i].id){r=&c->captures[i];break;}if(!r){if(c->ncaptures>=MAX_CAPTURES)return 0;r=&c->captures[c->ncaptures++];}memset(r,0,sizeof(*r));r->c=c;r->id=++c->next_capture;r->top=t;r->fd=-1;r->source=ext_foreign_toplevel_image_capture_source_manager_v1_create_source(c->top_source,t->wl);r->session=ext_image_copy_capture_manager_v1_create_session(c->copy_manager,r->source,0);ext_image_copy_capture_session_v1_add_listener(r->session,&session_listener,r);wl_display_roundtrip(c->display);return r->id;}
void nest_wl_destroy_capture(struct nest_wl_client*c,uint32_t id){struct capture_rec*r=capture_by_id(c,id);if(!r)return;if(r->frame)ext_image_copy_capture_frame_v1_destroy(r->frame);if(r->texture){eglMakeCurrent(c->egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,c->egl_context);glDeleteTextures(1,&r->texture);}capture_release_buffer(r);if(r->session)ext_image_copy_capture_session_v1_destroy(r->session);if(r->source)ext_image_capture_source_v1_destroy(r->source);memset(r,0,sizeof(*r));}
int nest_wl_capture_frame(struct nest_wl_client*c,uint32_t id){struct capture_rec*r=capture_by_id(c,id);if(!r||!r->constraints||r->capturing)return 0;if(r->frame){ext_image_copy_capture_frame_v1_destroy(r->frame);r->frame=NULL;}if((r->buffer_width!=r->width||r->buffer_height!=r->height||r->buffer_format!=r->format)&&r->buffer)capture_release_buffer(r);if(!r->buffer&&!capture_buffer(r))return 0;r->frame=ext_image_copy_capture_session_v1_create_frame(r->session);ext_image_copy_capture_frame_v1_add_listener(r->frame,&capture_listener,r);ext_image_copy_capture_frame_v1_attach_buffer(r->frame,r->buffer);ext_image_copy_capture_frame_v1_damage_buffer(r->frame,0,0,r->width,r->height);ext_image_copy_capture_frame_v1_capture(r->frame);r->capturing=1;wl_display_flush(c->display);return 1;}
int nest_wl_capture_info(struct nest_wl_client*c,uint32_t id,struct nest_wl_capture_info*x){struct capture_rec*r=capture_by_id(c,id);if(!r||!x)return 0;x->width=r->width;x->height=r->height;x->format=r->format;x->generation=r->generation;x->ready=r->ready!=0;return 1;}
