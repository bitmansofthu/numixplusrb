#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <sys/syscall.h>

/* Enforce GLIBC_2.4 versioning for libdl on glibc 2.13 */
__asm__(".symver dlsym, dlsym@GLIBC_2.4");
__asm__(".symver dlopen, dlopen@GLIBC_2.4");
__asm__(".symver dlerror, dlerror@GLIBC_2.4");
__asm__(".symver dlclose, dlclose@GLIBC_2.4");

#ifndef SYS_mmap2
#define SYS_mmap2 __NR_mmap2
#endif

/* rbp's user_space_rtc_init() calls mmap(MAP_SHARED, fd=-1) after /dev/mem open
 * fails (we chmod 000 /dev/mem). That mmap returns MAP_FAILED and leaves a
 * dangling RTC pointer (0x10000023) which later causes SIGSEGV loops -> watchdog.
 * Redirect that broken combination to an anonymous private mapping so it succeeds
 * with zeroed memory and sched_clock/v2_get_cycles read 0 instead of crashing. */
void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset)
{
    if (fd < 0 && (flags & MAP_SHARED) && !(flags & MAP_ANONYMOUS)) {
        flags = (flags & ~MAP_SHARED) | MAP_PRIVATE | MAP_ANONYMOUS;
        fd = -1;
        offset = 0;
    }
    return (void *)syscall(SYS_mmap2, addr, length, prot, flags, fd,
                           (unsigned long)offset >> 12);
}

#define LOG_PATH "/tmp/audioshim.log"

static void alog(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    int fd = open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) {
        write(fd, buf, strlen(buf));
        close(fd);
    }
}

/* Opaque ALSA types */
typedef void snd_pcm_t;
typedef void snd_pcm_hw_params_t;
typedef void snd_pcm_sw_params_t;
typedef unsigned long snd_pcm_uframes_t;
typedef long snd_pcm_sframes_t;

#define SND_PCM_STREAM_PLAYBACK 0
#define SND_PCM_STREAM_CAPTURE  1
#define SND_PCM_ACCESS_RW_INTERLEAVED 3
#define SND_PCM_FORMAT_S24_LE   6

/* Virtual handles for secondary streams */
static int g_h_hp     = 1;
static int g_h_booth  = 2;
static int g_h_dummy  = 3;
static int g_h_cap    = 4;

static snd_pcm_t *g_real_playback = NULL;
static int g_playback_open_count  = 0;

/* Real ALSA function pointers */
static int (*real_snd_pcm_open)(snd_pcm_t **, const char *, int, int) = NULL;
static int (*real_snd_pcm_close)(snd_pcm_t *) = NULL;
static int (*real_snd_pcm_hw_params)(snd_pcm_t *, snd_pcm_hw_params_t *) = NULL;
static int (*real_snd_pcm_hw_params_any)(snd_pcm_t *, snd_pcm_hw_params_t *) = NULL;
static int (*real_snd_pcm_hw_params_set_access)(snd_pcm_t *, snd_pcm_hw_params_t *, int) = NULL;
static int (*real_snd_pcm_hw_params_set_format)(snd_pcm_t *, snd_pcm_hw_params_t *, int) = NULL;
static int (*real_snd_pcm_hw_params_set_channels)(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned int) = NULL;
static int (*real_snd_pcm_hw_params_set_rate_near)(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned int *, int *) = NULL;
static int (*real_snd_pcm_hw_params_set_period_size_near)(snd_pcm_t *, snd_pcm_hw_params_t *, snd_pcm_uframes_t *, int *) = NULL;
static int (*real_snd_pcm_hw_params_set_periods_near)(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned int *, int *) = NULL;
static int (*real_snd_pcm_sw_params_current)(snd_pcm_t *, snd_pcm_sw_params_t *) = NULL;
static int (*real_snd_pcm_sw_params_get_boundary)(const snd_pcm_sw_params_t *, snd_pcm_uframes_t *) = NULL;
static int (*real_snd_pcm_sw_params_set_silence_threshold)(snd_pcm_t *, snd_pcm_sw_params_t *, snd_pcm_uframes_t) = NULL;
static int (*real_snd_pcm_sw_params_set_silence_size)(snd_pcm_t *, snd_pcm_sw_params_t *, snd_pcm_uframes_t) = NULL;
static int (*real_snd_pcm_sw_params_set_start_threshold)(snd_pcm_t *, snd_pcm_sw_params_t *, snd_pcm_uframes_t) = NULL;
static int (*real_snd_pcm_sw_params_set_stop_threshold)(snd_pcm_t *, snd_pcm_sw_params_t *, snd_pcm_uframes_t) = NULL;
static int (*real_snd_pcm_sw_params)(snd_pcm_t *, snd_pcm_sw_params_t *) = NULL;
static int (*real_snd_pcm_prepare)(snd_pcm_t *) = NULL;
static snd_pcm_sframes_t (*real_snd_pcm_writei)(snd_pcm_t *, const void *, snd_pcm_uframes_t) = NULL;
/* Control interface types */
typedef void snd_ctl_t;
typedef void snd_pcm_info_t;

static int (*real_snd_ctl_open)(snd_ctl_t **, const char *, int) = NULL;
static int (*real_snd_ctl_close)(snd_ctl_t *) = NULL;

static void init_real_alsa(void)
{
    static int initialized = 0;
    if (initialized) return;
    initialized = 1;

    void *lib = dlopen("libasound.so.2", RTLD_LAZY | RTLD_GLOBAL);
    if (!lib) {
        alog("audioshim: failed to dlopen libasound.so.2: %s\n", dlerror());
        return;
    }

    real_snd_pcm_open = dlsym(lib, "snd_pcm_open");
    real_snd_pcm_close = dlsym(lib, "snd_pcm_close");
    real_snd_pcm_hw_params = dlsym(lib, "snd_pcm_hw_params");
    real_snd_pcm_hw_params_any = dlsym(lib, "snd_pcm_hw_params_any");
    real_snd_pcm_hw_params_set_access = dlsym(lib, "snd_pcm_hw_params_set_access");
    real_snd_pcm_hw_params_set_format = dlsym(lib, "snd_pcm_hw_params_set_format");
    real_snd_pcm_hw_params_set_channels = dlsym(lib, "snd_pcm_hw_params_set_channels");
    real_snd_pcm_hw_params_set_rate_near = dlsym(lib, "snd_pcm_hw_params_set_rate_near");
    real_snd_pcm_hw_params_set_period_size_near = dlsym(lib, "snd_pcm_hw_params_set_period_size_near");
    real_snd_pcm_hw_params_set_periods_near = dlsym(lib, "snd_pcm_hw_params_set_periods_near");
    real_snd_pcm_sw_params_current = dlsym(lib, "snd_pcm_sw_params_current");
    real_snd_pcm_sw_params_get_boundary = dlsym(lib, "snd_pcm_sw_params_get_boundary");
    real_snd_pcm_sw_params_set_silence_threshold = dlsym(lib, "snd_pcm_sw_params_set_silence_threshold");
    real_snd_pcm_sw_params_set_silence_size = dlsym(lib, "snd_pcm_sw_params_set_silence_size");
    real_snd_pcm_sw_params_set_start_threshold = dlsym(lib, "snd_pcm_sw_params_set_start_threshold");
    real_snd_pcm_sw_params_set_stop_threshold = dlsym(lib, "snd_pcm_sw_params_set_stop_threshold");
    real_snd_pcm_sw_params = dlsym(lib, "snd_pcm_sw_params");
    real_snd_pcm_prepare = dlsym(lib, "snd_pcm_prepare");
    real_snd_pcm_writei = dlsym(lib, "snd_pcm_writei");
    real_snd_ctl_open = dlsym(lib, "snd_ctl_open");
    real_snd_ctl_close = dlsym(lib, "snd_ctl_close");

    alog("audioshim: real ALSA initialized\n");
}

/* Output layout.  Defaults are the Numark Mixstream Pro (NH08):
 *   ch0/1 = master, ch2/3 = headphones, ch4/5 = built-in speakers.
 * A 4-channel PCM leaves the speaker DAI out entirely (the kernel machine
 * driver sets its channels_min to 0), so phase 1 does not touch the amp.
 * Set AUDIO_CHANNELS=6 to include the speaker slots, and AUDIO_SPEAKERS=0
 * to open 6 channels but keep the speaker slots silent.
 *
 * The SC Live 4 (JP21) layout is still reachable:
 *   AUDIO_CHANNELS=8 AUDIO_HP_OFFSET=4 AUDIO_SPEAKER_OFFSET=6
 * (it also has a booth pair at 2/3, which this shim does not feed.)
 *
 * All offsets are in interleaved L/R pairs.  They can be overridden for
 * bring-up if the master/headphone pair turns out to be swapped:
 *   AUDIO_MASTER_OFFSET=2 AUDIO_HP_OFFSET=0
 */
#define MAX_FRAMES 4096
#define MAX_OUTPUT_CHANNELS 8

static int g_out_channels = 4;
static int g_master_offset = 0;
static int g_hp_offset = 2;
static int g_speaker_offset = 4;
static int g_speakers_enabled = -1;   /* -1 = auto (on when slots exist) */
static char g_device[128] = "hw:1,0";
static int g_config_initialized = 0;

static int32_t g_mixch[MAX_FRAMES * MAX_OUTPUT_CHANNELS];
static unsigned long g_write_count = 0;

static int env_int(const char *name, int def)
{
    const char *s = getenv(name);
    return (s && *s) ? atoi(s) : def;
}

static int pairs_overlap(int a, int b)
{
    return a >= 0 && b >= 0 && a < b + 2 && b < a + 2;
}

static void audio_config_init(void)
{
    if (g_config_initialized) return;
    g_config_initialized = 1;

    const char *s = getenv("AUDIO_DEVICE");
    if (s && *s)
        snprintf(g_device, sizeof(g_device), "%s", s);

    int channels = env_int("AUDIO_CHANNELS", 4);
    if (channels < 2 || channels > MAX_OUTPUT_CHANNELS || (channels & 1)) {
        alog("audioshim: invalid AUDIO_CHANNELS=%d, using 4\n", channels);
        channels = 4;
    }
    g_out_channels = channels;

    g_master_offset = env_int("AUDIO_MASTER_OFFSET", 0);
    g_hp_offset = env_int("AUDIO_HP_OFFSET", 2);
    g_speaker_offset = env_int("AUDIO_SPEAKER_OFFSET", 4);

    if (g_master_offset < 0 ||
        g_master_offset + 2 > g_out_channels) {
        alog("audioshim: invalid AUDIO_MASTER_OFFSET=%d, using 0\n",
             g_master_offset);
        g_master_offset = 0;
    }
    if (g_hp_offset >= 0 && g_hp_offset + 2 > g_out_channels) {
        alog("audioshim: headphone slots %d/%d do not fit in %d channels\n",
             g_hp_offset, g_hp_offset + 1, g_out_channels);
        g_hp_offset = -1;
    }
    if (g_speaker_offset >= 0 &&
        g_speaker_offset + 2 > g_out_channels) {
        if (env_int("AUDIO_SPEAKERS", 0) != 0)
            alog("audioshim: speaker slots %d/%d need at least %d channels\n",
                 g_speaker_offset, g_speaker_offset + 1,
                 g_speaker_offset + 2);
        g_speaker_offset = -1;
    }

    if (pairs_overlap(g_master_offset, g_hp_offset)) {
        alog("audioshim: headphone slots overlap master slots; disabling hp\n");
        g_hp_offset = -1;
    }
    if (pairs_overlap(g_master_offset, g_speaker_offset) ||
        pairs_overlap(g_hp_offset, g_speaker_offset)) {
        alog("audioshim: speaker slots overlap another output; disabling speakers\n");
        g_speaker_offset = -1;
    }

    s = getenv("AUDIO_SPEAKERS");
    if (s && *s)
        g_speakers_enabled = (atoi(s) != 0);
    else
        g_speakers_enabled = (g_speaker_offset >= 0);
    if (g_speaker_offset < 0)
        g_speakers_enabled = 0;

    char hp_desc[32], spk_desc[32];
    if (g_hp_offset >= 0)
        snprintf(hp_desc, sizeof(hp_desc), "%d/%d",
                 g_hp_offset, g_hp_offset + 1);
    else
        snprintf(hp_desc, sizeof(hp_desc), "off");
    if (g_speakers_enabled)
        snprintf(spk_desc, sizeof(spk_desc), "%d/%d",
                 g_speaker_offset, g_speaker_offset + 1);
    else
        snprintf(spk_desc, sizeof(spk_desc), "off");

    alog("audioshim: layout device=%s channels=%d master=%d/%d hp=%s speakers=%s\n",
         g_device, g_out_channels,
         g_master_offset, g_master_offset + 1,
         hp_desc, spk_desc);
}

/* shared with knobshim2.so (booth/speaker knob, CC15 ch15) */
extern volatile float g_speaker_gain;

/* shared with knobshim2.so: headphone cue mix/level (CC18/CC19 ch15).
 * g_cue_mix: 0 = cue only, 1 = main only.  g_cue_gain: 0..1. */
extern volatile float g_cue_gain;
extern volatile float g_cue_mix;
/* shared with knobshim2.so: XLR/main-out level (Main Vol, CC20 ch15) */
extern volatile float g_master_gain;
/* shared with knobshim2.so: built-in monitor on/off switch (ch15 note 41) */
extern volatile int g_speaker_on;
/* shared with knobshim2.so: split-cue switch (ch15 note 11) */
extern volatile int g_split_cue;

/* rbp's phone stream is the CUE (PFL) bus; keep it in its own buffer so the
 * master write can blend it without ordering hazards. */
static int32_t g_cue[MAX_FRAMES * 2];
static int g_has_cue = 0;

/* shared with knobshim2.so: master VU peaks (S24_LE full scale 0xFFFFFF).
 * knobshim turns these into the SC Live 4 meter CCs (CC32/33 on ch15). */
extern volatile int g_vu_peak[2];

/* per-sample smoothed speaker gain (avoids zipper noise when the knob moves) */
static float g_sg_cur = 1.0f;

/* Effective speaker gain: SPEAKER_GAIN env var overrides the knob (fixed
 * 0..1 for testing); otherwise the shared knob value from knobshim2.so. */
static float g_fixed_gain = -1.0f;  /* <0 = use the booth/speaker knob (CC15) */
static int g_fixed_checked = 0;

static float speaker_gain(void)
{
    if (!g_fixed_checked) {
        g_fixed_checked = 1;
        const char *s = getenv("SPEAKER_GAIN");
        if (s && *s)
            g_fixed_gain = (float)atof(s);
    }
    float sg = (g_fixed_gain >= 0.0f) ? g_fixed_gain : g_speaker_gain;
    if (sg > 1.0f) sg = 1.0f;
    if (sg < 0.0f) sg = 0.0f;
    if (sg != sg) sg = 0.0f;   /* NaN guard */
    return sg;
}

/* ---- Startup mute / fade-in --------------------------------------------
 * The JP21 codec/DSP emits a loud ~100 ms transient right after the stream
 * starts (before rbp's audio engine has produced real audio).  Silence every
 * output channel for STARTUP_MUTE_MS after the first write, then linearly
 * fade back in over STARTUP_FADE_MS so the unmute itself cannot click.
 *   STARTUP_MUTE_MS=0  -> disabled
 *   STARTUP_MUTE_MS    default 1500 ms
 *   STARTUP_FADE_MS    default 300 ms */
static long g_startup_mute_frames = -1;   /* -1 = env not read yet */
static long g_startup_fade_frames = -1;
static unsigned long long g_startup_frames_done = 0;  /* master frames written */
static int g_startup_logged_mute = 0;
static int g_startup_logged_open = 0;

static void startup_env_init(void)
{
    if (g_startup_mute_frames >= 0) return;
    long mute_ms = 1500, fade_ms = 300;
    const char *s = getenv("STARTUP_MUTE_MS");
    if (s && *s) mute_ms = atol(s);
    s = getenv("STARTUP_FADE_MS");
    if (s && *s) fade_ms = atol(s);
    if (mute_ms < 0) mute_ms = 0;
    if (fade_ms < 0) fade_ms = 0;
    g_startup_mute_frames = mute_ms * 44100L / 1000L;
    g_startup_fade_frames = fade_ms * 44100L / 1000L;
    alog("audioshim: startup mute=%ldms fade=%ldms (%ld+%ld frames)\n",
         mute_ms, fade_ms, g_startup_mute_frames, g_startup_fade_frames);
}

static inline int is_real(snd_pcm_t *pcm)
{
    return (pcm && pcm == g_real_playback);
}

int snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode)
{
    init_real_alsa();
    audio_config_init();
    alog("audioshim: snd_pcm_open(name='%s', stream=%d, mode=%d)\n", name ? name : "null", stream, mode);

    if (stream == SND_PCM_STREAM_PLAYBACK) {
        if (g_playback_open_count == 0) {
            /* Output 0: Master -> real hardware */
            if (!g_real_playback && real_snd_pcm_open) {
                int real_mode = mode & ~2; /* mask out SND_PCM_NONBLOCK so hardware paces audio clock */
                int err = real_snd_pcm_open(&g_real_playback, g_device, SND_PCM_STREAM_PLAYBACK, real_mode);
                alog("audioshim: opened real %s for Master (mode=%d->%d), res=%d handle=%p\n",
                     g_device, mode, real_mode, err, g_real_playback);
                if (err < 0) {
                    err = real_snd_pcm_open(&g_real_playback, "default", SND_PCM_STREAM_PLAYBACK, real_mode);
                    alog("audioshim: fallback open 'default' res=%d handle=%p\n", err, g_real_playback);
                }
            }
            *pcm = g_real_playback;
            g_playback_open_count++;
            return 0;
        } else if (g_playback_open_count == 1) {
            /* Output 1: Headphone -> Virtual handle */
            alog("audioshim: mapped virtual Headphone device\n");
            *pcm = (snd_pcm_t *)&g_h_hp;
            g_playback_open_count++;
            return 0;
        } else if (g_playback_open_count == 2) {
            /* Output 2: Booth -> Virtual handle (discarded on NH08) */
            alog("audioshim: mapped virtual Booth device (no output)\n");
            *pcm = (snd_pcm_t *)&g_h_booth;
            g_playback_open_count++;
            return 0;
        } else {
            alog("audioshim: mapped dummy output device %d\n", g_playback_open_count);
            *pcm = (snd_pcm_t *)&g_h_dummy;
            g_playback_open_count++;
            return 0;
        }
    } else {
        /* Capture / Mic -> Always virtual handle to prevent hardware contention */
        alog("audioshim: mapped virtual Capture device\n");
        *pcm = (snd_pcm_t *)&g_h_cap;
        return 0;
    }
}

int snd_pcm_close(snd_pcm_t *pcm)
{
    init_real_alsa();
    alog("audioshim: snd_pcm_close(handle=%p)\n", pcm);

    if (is_real(pcm)) {
        if (g_real_playback && real_snd_pcm_close) {
            real_snd_pcm_close(g_real_playback);
            g_real_playback = NULL;
        }
        g_playback_open_count = 0;
    }
    return 0;
}

int snd_pcm_hw_params_any(snd_pcm_t *pcm, snd_pcm_hw_params_t *params)
{
    init_real_alsa();
    if (is_real(pcm) && real_snd_pcm_hw_params_any)
        return real_snd_pcm_hw_params_any(g_real_playback, params);
    return 0;
}

int snd_pcm_hw_params_set_access(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, int access)
{
    init_real_alsa();
    alog("audioshim: set_access req=%d\n", access);
    if (is_real(pcm) && real_snd_pcm_hw_params_set_access)
        return real_snd_pcm_hw_params_set_access(g_real_playback, params, access);
    return 0;
}

int snd_pcm_hw_params_set_format(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, int format)
{
    init_real_alsa();
    alog("audioshim: set_format req=%d\n", format);
    /* Prime GO hw:1,0 natively supports S24_LE (format 6) */
    if (is_real(pcm) && real_snd_pcm_hw_params_set_format) {
        int err = real_snd_pcm_hw_params_set_format(g_real_playback, params, SND_PCM_FORMAT_S24_LE);
        alog("audioshim: real set_format(S24_LE=6) res=%d\n", err);
        return err;
    }
    return 0;
}

int snd_pcm_hw_params_set_channels(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int val)
{
    init_real_alsa();
    audio_config_init();
    alog("audioshim: set_channels req=%u -> setting %dch on hw\n", val, g_out_channels);
    if (is_real(pcm) && real_snd_pcm_hw_params_set_channels) {
        int err = real_snd_pcm_hw_params_set_channels(g_real_playback, params, g_out_channels);
        alog("audioshim: real set_channels(%d) res=%d\n", g_out_channels, err);
        return err;
    }
    return 0;
}

int snd_pcm_hw_params_set_rate_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int *dir)
{
    init_real_alsa();
    alog("audioshim: set_rate_near req=%u\n", val ? *val : 0);
    if (is_real(pcm) && real_snd_pcm_hw_params_set_rate_near) {
        if (val) *val = 44100;
        int err = real_snd_pcm_hw_params_set_rate_near(g_real_playback, params, val, dir);
        alog("audioshim: real set_rate_near res=%d rate=%u\n", err, val ? *val : 0);
        return err;
    }
    if (val) *val = 44100;
    return 0;
}

int snd_pcm_hw_params_set_period_size_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val, int *dir)
{
    init_real_alsa();
    alog("audioshim: set_period_size_near req=%lu\n", val ? *val : 0);
    if (is_real(pcm) && real_snd_pcm_hw_params_set_period_size_near) {
        int err = real_snd_pcm_hw_params_set_period_size_near(g_real_playback, params, val, dir);
        alog("audioshim: real set_period_size_near res=%d period=%lu\n", err, val ? *val : 0);
        return err;
    }
    return 0;
}

int snd_pcm_hw_params_set_periods_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int *dir)
{
    init_real_alsa();
    alog("audioshim: set_periods_near req=%u\n", val ? *val : 0);
    if (is_real(pcm) && real_snd_pcm_hw_params_set_periods_near) {
        int err = real_snd_pcm_hw_params_set_periods_near(g_real_playback, params, val, dir);
        alog("audioshim: real set_periods_near res=%d periods=%u\n", err, val ? *val : 0);
        return err;
    }
    return 0;
}

int snd_pcm_hw_params_get_channels_min(const snd_pcm_hw_params_t *params, unsigned int *val)
{
    if (val) *val = 2;
    return 0;
}

int snd_pcm_hw_params_get_channels_max(const snd_pcm_hw_params_t *params, unsigned int *val)
{
    if (val) *val = 2;
    return 0;
}

int snd_pcm_hw_params_test_rate(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int rate)
{
    return (rate == 44100) ? 0 : -EINVAL;
}

int snd_pcm_hw_params(snd_pcm_t *pcm, snd_pcm_hw_params_t *params)
{
    init_real_alsa();
    alog("audioshim: snd_pcm_hw_params(pcm=%p)\n", pcm);
    if (is_real(pcm) && real_snd_pcm_hw_params) {
        int err = real_snd_pcm_hw_params(g_real_playback, params);
        alog("audioshim: real hw_params res=%d\n", err);
        return err;
    }
    return 0;
}

int snd_pcm_sw_params_current(snd_pcm_t *pcm, snd_pcm_sw_params_t *params)
{
    init_real_alsa();
    int err = 0;
    if (is_real(pcm) && real_snd_pcm_sw_params_current) {
        err = real_snd_pcm_sw_params_current(g_real_playback, params);
    }
    alog("audioshim: snd_pcm_sw_params_current(pcm=%p) res=%d\n", pcm, err);
    return err;
}

int snd_pcm_sw_params_get_boundary(const snd_pcm_sw_params_t *params, snd_pcm_uframes_t *val)
{
    init_real_alsa();
    int err = 0;
    if (real_snd_pcm_sw_params_get_boundary) {
        err = real_snd_pcm_sw_params_get_boundary(params, val);
    }
    if (err != 0 || !val || *val == 0) {
        if (val) *val = 0x40000000;
        err = 0;
    }
    alog("audioshim: get_boundary() res=%d val=%lx\n", err, val ? *val : 0);
    return err;
}

int snd_pcm_sw_params_set_silence_threshold(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t val)
{
    init_real_alsa();
    int err = 0;
    if (is_real(pcm) && real_snd_pcm_sw_params_set_silence_threshold) {
        err = real_snd_pcm_sw_params_set_silence_threshold(g_real_playback, params, val);
    }
    alog("audioshim: set_silence_threshold(%lu) res=%d\n", val, err);
    return 0; /* always succeed */
}

int snd_pcm_sw_params_set_silence_size(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t val)
{
    init_real_alsa();
    int err = 0;
    if (is_real(pcm) && real_snd_pcm_sw_params_set_silence_size) {
        err = real_snd_pcm_sw_params_set_silence_size(g_real_playback, params, val);
    }
    alog("audioshim: set_silence_size(%lu) res=%d\n", val, err);
    return 0; /* always succeed */
}

int snd_pcm_sw_params_set_start_threshold(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t val)
{
    init_real_alsa();
    int err = 0;
    if (is_real(pcm) && real_snd_pcm_sw_params_set_start_threshold) {
        err = real_snd_pcm_sw_params_set_start_threshold(g_real_playback, params, val);
    }
    alog("audioshim: set_start_threshold(%lu) res=%d\n", val, err);
    return 0; /* always succeed */
}

int snd_pcm_sw_params_set_stop_threshold(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t val)
{
    init_real_alsa();
    int err = 0;
    if (is_real(pcm) && real_snd_pcm_sw_params_set_stop_threshold) {
        err = real_snd_pcm_sw_params_set_stop_threshold(g_real_playback, params, val);
    }
    alog("audioshim: set_stop_threshold(%lu) res=%d\n", val, err);
    return 0; /* always succeed */
}

int snd_pcm_sw_params(snd_pcm_t *pcm, snd_pcm_sw_params_t *params)
{
    init_real_alsa();
    int err = 0;
    if (is_real(pcm) && real_snd_pcm_sw_params) {
        err = real_snd_pcm_sw_params(g_real_playback, params);
    }
    alog("audioshim: snd_pcm_sw_params(pcm=%p) res=%d\n", pcm, err);
    return 0; /* always succeed */
}

int snd_pcm_prepare(snd_pcm_t *pcm)
{
    init_real_alsa();
    int err = 0;
    if (is_real(pcm) && real_snd_pcm_prepare) {
        err = real_snd_pcm_prepare(g_real_playback);
    }
    alog("audioshim: snd_pcm_prepare(pcm=%p) res=%d\n", pcm, err);
    return 0; /* always succeed */
}

int snd_pcm_link(snd_pcm_t *pcm1, snd_pcm_t *pcm2)
{
    alog("audioshim: snd_pcm_link intercepted -> success\n");
    return 0;
}

snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, snd_pcm_uframes_t size)
{
    init_real_alsa();
    audio_config_init();
    if (!buffer || size == 0) return size;

    if (size > MAX_FRAMES)
        size = MAX_FRAMES;

    const int32_t *src = (const int32_t *)buffer;
    static int32_t s_peak_master = 0;
    static int32_t s_peak_hp = 0;

    if (pcm == (snd_pcm_t *)&g_h_hp) {
        /* Headphone/cue stream (rbp device 1) -> cue bus buffer */
        for (snd_pcm_uframes_t i = 0; i < size; i++) {
            int32_t l = src[i * 2 + 0];
            int32_t r = src[i * 2 + 1];
            /* rbp's S24_LE samples are right-justified but NOT sign-extended
             * (top byte 0), so sign-extend before measuring/abs() */
            int32_t sl = (int32_t)(l << 8) >> 8;
            int32_t sr = (int32_t)(r << 8) >> 8;
            int32_t al = (sl < 0) ? -sl : sl;
            int32_t ar = (sr < 0) ? -sr : sr;
            if (al > s_peak_hp) s_peak_hp = al;
            if (ar > s_peak_hp) s_peak_hp = ar;
            g_cue[i * 2 + 0] = sl;   /* store true signed S24 */
            g_cue[i * 2 + 1] = sr;
        }
        if (s_peak_hp > 100) g_has_cue = 1;
        return size;
    }

    if (pcm == (snd_pcm_t *)&g_h_booth) {
        /* rbp's booth stream has no output path on NH08.  Discard it so it
         * cannot clobber the headphone slots (2/3 on the Mixstream Pro). */
        static int booth_logged = 0;
        if (!booth_logged) {
            booth_logged = 1;
            alog("audioshim: booth stream discarded (no booth output)\n");
        }
        return size;
    }
    if (pcm == (snd_pcm_t *)&g_h_dummy)
        return size;

    int master_off = g_master_offset;
    int hp_off = g_hp_offset;
    int spk_off = g_speakers_enabled ? g_speaker_offset : -1;

    /* Master stream: interleave into the configured master, headphone and
     * (optionally) speaker slots. */
    float sg_target = (spk_off >= 0 && g_speaker_on) ? speaker_gain() : 0.0f;
    float cue_mix = g_cue_mix;
    float cue_gain = g_cue_gain;
    float master_gain = g_master_gain;
    if (cue_mix < 0.0f) cue_mix = 0.0f;
    if (cue_mix > 1.0f) cue_mix = 1.0f;
    if (cue_gain < 0.0f) cue_gain = 0.0f;
    if (cue_gain > 1.0f) cue_gain = 1.0f;
    if (master_gain < 0.0f) master_gain = 0.0f;
    if (master_gain > 1.0f) master_gain = 1.0f;
    static float env_l = 0.0f, env_r = 0.0f;
    /* Per-block VU release.  The old fixed 0.995 took ~300 ms to fall 60 dB
     * (one block is ~1.45 ms), which made the panel meters feel sluggish.
     * 0.98 falls in ~70 ms; VU_RELEASE=<factor> overrides it at startup. */
    static float vu_release = 0.0f;
    static int vu_release_init = 0;
    if (!vu_release_init) {
        const char *s = getenv("VU_RELEASE");
        vu_release_init = 1;
        vu_release = (s && *s) ? (float)atof(s) : 0.98f;
        if (vu_release < 0.5f)
            vu_release = 0.5f;
        if (vu_release > 1.0f)
            vu_release = 1.0f;
    }
    int32_t bl = 0, br = 0;
    memset(g_mixch, 0, (size_t)size * g_out_channels * sizeof(g_mixch[0]));
    for (snd_pcm_uframes_t i = 0; i < size; i++) {
        int32_t l = src[i * 2 + 0];
        int32_t r = src[i * 2 + 1];
        /* true signed 24-bit values (see the HP branch) for peak/VU */
        int32_t sl = (int32_t)(l << 8) >> 8;
        int32_t sr = (int32_t)(r << 8) >> 8;
        int32_t al = (sl < 0) ? -sl : sl;
        int32_t ar = (sr < 0) ? -sr : sr;
        if (al > s_peak_master) s_peak_master = al;
        if (ar > s_peak_master) s_peak_master = ar;
        /* master VU is POST Main-Vol (like a real mixer) */
        {
            int32_t mvl = (int32_t)(al * master_gain);
            int32_t mvr = (int32_t)(ar * master_gain);
            if (mvl > bl) bl = mvl;
            if (mvr > br) br = mvr;
        }
        /* Scale the TRUE signed 24-bit values (sl/sr).  Scaling the raw word
         * would corrupt negative samples, whose top byte is 0 here. */
        g_mixch[i * g_out_channels + master_off + 0] =
            (int32_t)(sl * master_gain);  /* main L */
        g_mixch[i * g_out_channels + master_off + 1] =
            (int32_t)(sr * master_gain);  /* main R */
        /* ramp the speaker gain per-sample so knob moves don't create a
         * block-rate staircase (689 Hz buzz heard as "noise") */
        if (spk_off >= 0) {
            g_sg_cur += (sg_target - g_sg_cur) * 0.0008f;
            g_mixch[i * g_out_channels + spk_off + 0] =
                (int32_t)(sl * g_sg_cur);  /* speakers L */
            g_mixch[i * g_out_channels + spk_off + 1] =
                (int32_t)(sr * g_sg_cur);  /* speakers R */
        }
        /* rbp's phone stream is its headphone bus.  With rbp's MASTER CUE
         * enabled the bus contains cue + master, already mixed and
         * time-aligned by rbp - route it straight through instead of summing
         * the separate master/cue streams here (that combed). */
        if (hp_off >= 0) {
            g_mixch[i * g_out_channels + hp_off + 0] = g_cue[i * 2 + 0];
            g_mixch[i * g_out_channels + hp_off + 1] = g_cue[i * 2 + 1];
        }
    }

    g_write_count++;

    /* publish decaying master peaks for the panel VU meters; the attack is
     * immediate and the release is VU_RELEASE per block (default 0.98) */
    env_l = ((float)bl > env_l) ? (float)bl : env_l * vu_release;
    env_r = ((float)br > env_r) ? (float)br : env_r * vu_release;
    g_vu_peak[0] = (int)env_l;
    g_vu_peak[1] = (int)env_r;

    /* startup mute + fade-in: scale every output channel (master, cue/booth,
     * built-in speakers) so the codec's power-up transient is never heard */
    startup_env_init();
    {
        unsigned long long t0   = g_startup_frames_done;
        unsigned long long mute = (unsigned long long)g_startup_mute_frames;
        unsigned long long fade = (unsigned long long)g_startup_fade_frames;
        g_startup_frames_done += size;

        if (mute > 0 && t0 < mute + fade) {
            if (!g_startup_logged_mute) {
                g_startup_logged_mute = 1;
                alog("audioshim: startup mute active: %llu+%llu frames (~%.1fs)\n",
                     mute, fade, (double)(mute + fade) / 44100.0);
            }
            for (snd_pcm_uframes_t i = 0; i < size; i++) {
                unsigned long long t = t0 + i;
                float g;
                if (t < mute)
                    g = 0.0f;
                else if (fade > 0 && t < mute + fade)
                    g = (float)(t - mute) / (float)fade;
                else
                    g = 1.0f;
                if (g >= 1.0f) continue;
                for (int c = 0; c < g_out_channels; c++)
                    g_mixch[i * g_out_channels + c] =
                        (int32_t)((float)g_mixch[i * g_out_channels + c] * g);
            }
        }
        if (!g_startup_logged_open && mute > 0 && g_startup_frames_done >= mute + fade) {
            g_startup_logged_open = 1;
            alog("audioshim: startup mute released after %llu frames\n",
                 g_startup_frames_done);
        }
    }

    snd_pcm_sframes_t written = 0;
    /* Output all configured channels to real hardware */
    if (g_real_playback && real_snd_pcm_writei) {
        written = real_snd_pcm_writei(g_real_playback, g_mixch, size);
        if (written < 0) {
            if (real_snd_pcm_prepare)
                real_snd_pcm_prepare(g_real_playback);
            written = real_snd_pcm_writei(g_real_playback, g_mixch, size);
        }
    } else {
        /* Safety sleep to pace real-time audio threads if hardware is delayed */
        usleep(size * 1000000 / 44100);
    }

    if ((g_write_count % 500) == 1) {
        alog("audioshim: writei #%lu frames=%lu ch=%d written=%ld peak_m=%d peak_hp=%d sg=%.4f cm=%.4f cg=%.4f\n",
             g_write_count, size, g_out_channels, (long)written,
             s_peak_master, s_peak_hp,
             (double)speaker_gain(), (double)g_cue_mix, (double)g_cue_gain);
        /* cue/master alignment diagnostic removed (direct routing) */
        s_peak_master = 0;
        s_peak_hp = 0;
    }

    return size;
}

snd_pcm_sframes_t snd_pcm_readi(snd_pcm_t *pcm, void *buffer, snd_pcm_uframes_t size)
{
    /* Always provide clean silence for capture to guarantee zero read errors */
    if (buffer && size > 0)
        memset(buffer, 0, size * 8);
    return size;
}

/* Control interface stubs */

int snd_ctl_open(snd_ctl_t **ctl, const char *name, int mode)
{
    init_real_alsa();
    alog("audioshim: snd_ctl_open(name='%s', mode=%d)\n", name ? name : "null", mode);
    if (real_snd_ctl_open && name && (strstr(name, "hw:1") || strstr(name, "hw:0") || strstr(name, "default"))) {
        int err = real_snd_ctl_open(ctl, name, mode);
        if (err == 0) return 0;
    }
    if (ctl) *ctl = (snd_ctl_t *)0x12345;
    return 0;
}

int snd_ctl_close(snd_ctl_t *ctl)
{
    init_real_alsa();
    alog("audioshim: snd_ctl_close(handle=%p)\n", ctl);
    if (ctl != (snd_ctl_t *)0x12345 && real_snd_ctl_close) {
        return real_snd_ctl_close(ctl);
    }
    return 0;
}

int snd_ctl_pcm_info(snd_ctl_t *ctl, snd_pcm_info_t *info)
{
    alog("audioshim: snd_ctl_pcm_info(ctl=%p)\n", ctl);
    return 0;
}

/* Scheduler & Affinity stubs to prevent single-core lockup on Rockchip */
int pthread_setaffinity_np(pthread_t thread, size_t cpusetsize, const void *cpuset)
{
    (void)thread; (void)cpusetsize; (void)cpuset;
    return 0;
}

int sched_setaffinity(pid_t pid, size_t cpusetsize, const void *cpuset)
{
    (void)pid; (void)cpusetsize; (void)cpuset;
    return 0;
}

int sched_setscheduler(pid_t pid, int policy, const void *param)
{
    (void)pid; (void)policy; (void)param;
    return 0;
}

int pthread_setschedparam(pthread_t thread, int policy, const void *param)
{
    (void)thread; (void)policy; (void)param;
    return 0; /* completely disable SCHED_FIFO/SCHED_RR starvation */
}

int pthread_setschedprio(pthread_t thread, int prio)
{
    (void)thread; (void)prio;
    return 0;
}

int pthread_attr_setschedpolicy(void *attr, int policy)
{
    (void)attr; (void)policy;
    return 0;
}

int pthread_attr_setschedparam(void *attr, const void *param)
{
    (void)attr; (void)param;
    return 0;
}


