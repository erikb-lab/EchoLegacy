#include "el_fmp4_adts.h"
#include <stdlib.h>
#include <string.h>

static inline uint16_t rd16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static inline uint32_t rd32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}

static inline uint64_t rd64(const uint8_t *p) {
    return ((uint64_t)rd32(p) << 32) | (uint64_t)rd32(p + 4);
}

static inline uint32_t fourcc(char a, char b, char c, char d) {
    return ((uint32_t)(uint8_t)a << 24) | ((uint32_t)(uint8_t)b << 16) |
           ((uint32_t)(uint8_t)c << 8)  |  (uint32_t)(uint8_t)d;
}

static const uint32_t k_aac_sample_rates[16] = {
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000,  7350,  0,     0,     0
};

typedef enum {
    STATE_BOX_HEADER = 0,
    STATE_BOX_EXTSIZE,
    STATE_BOX_BUFFER,
    STATE_BOX_SKIP,
    STATE_MDAT_STREAM
} parser_state_t;

struct el_fmp4_ctx {
    el_adts_frame_cb on_frame;
    void            *user_data;

    /* Stream position tracking */
    uint64_t stream_pos;

    /* Box header state */
    parser_state_t state;
    uint8_t  hdr_buf[8];
    size_t   hdr_pos;
    uint32_t box_type;
    uint64_t box_payload_rem;
    uint64_t box_end_pos;

    /* Buffered small boxes (moov / sidx / moof) */
    uint8_t *box_buf;
    size_t   box_buf_len;
    size_t   box_buf_cap;

    /* Audio config from moov/esds */
    int      has_config;
    uint8_t  adts_profile;   /* 0=Main, 1=LC, 2=SSR, 3=LTP */
    uint8_t  freq_idx;       /* 0..12 */
    uint8_t  chan_cfg;       /* 1..7 */
    uint32_t trex_default_sample_size;
    double   total_duration;

    /* sidx table */
    el_sidx_entry_t *sidx;
    size_t           sidx_count;

    /* Current moof trun sample sizes */
    uint32_t *sample_sizes;
    size_t    sample_count;
    size_t    sample_cap;
    size_t    sample_idx;

    /* Current AAC frame accumulator (7-byte ADTS header + raw frame) */
    uint8_t  *frame_buf;
    size_t    frame_cap;
    size_t    frame_filled;
};

el_fmp4_ctx_t *el_fmp4_create(el_adts_frame_cb on_frame, void *user_data) {
    el_fmp4_ctx_t *ctx = (el_fmp4_ctx_t *)calloc(1, sizeof(el_fmp4_ctx_t));
    if (!ctx) return NULL;
    ctx->on_frame = on_frame;
    ctx->user_data = user_data;
    /* Sensible default for YouTube itag 140 (AAC-LC, 44100 Hz, stereo) until moov overrides */
    ctx->adts_profile = 1;
    ctx->freq_idx = 4;
    ctx->chan_cfg = 2;
    ctx->state = STATE_BOX_HEADER;
    return ctx;
}

void el_fmp4_destroy(el_fmp4_ctx_t *ctx) {
    if (!ctx) return;
    free(ctx->box_buf);
    free(ctx->sidx);
    free(ctx->sample_sizes);
    free(ctx->frame_buf);
    free(ctx);
}

void el_fmp4_reset_for_seek(el_fmp4_ctx_t *ctx, uint64_t new_stream_offset) {
    if (!ctx) return;
    ctx->stream_pos = new_stream_offset;
    ctx->state = STATE_BOX_HEADER;
    ctx->hdr_pos = 0;
    ctx->box_type = 0;
    ctx->box_payload_rem = 0;
    ctx->box_buf_len = 0;
    ctx->sample_count = 0;
    ctx->sample_idx = 0;
    ctx->frame_filled = 0;
}

int el_fmp4_has_config(const el_fmp4_ctx_t *ctx) {
    return ctx ? ctx->has_config : 0;
}

uint32_t el_fmp4_sample_rate(const el_fmp4_ctx_t *ctx) {
    if (!ctx || ctx->freq_idx >= 16) return 44100;
    return k_aac_sample_rates[ctx->freq_idx] ? k_aac_sample_rates[ctx->freq_idx] : 44100;
}

uint8_t el_fmp4_channels(const el_fmp4_ctx_t *ctx) {
    return ctx ? ctx->chan_cfg : 2;
}

double el_fmp4_total_duration(const el_fmp4_ctx_t *ctx) {
    return ctx ? ctx->total_duration : 0.0;
}

uint64_t el_fmp4_stream_offset(const el_fmp4_ctx_t *ctx) {
    return ctx ? ctx->stream_pos : 0;
}

size_t el_fmp4_sidx_count(const el_fmp4_ctx_t *ctx) {
    return ctx ? ctx->sidx_count : 0;
}

const el_sidx_entry_t *el_fmp4_sidx_entry(const el_fmp4_ctx_t *ctx, size_t idx) {
    if (!ctx || idx >= ctx->sidx_count) return NULL;
    return &ctx->sidx[idx];
}

int el_fmp4_find_seek_offset(const el_fmp4_ctx_t *ctx, double target_sec,
                             uint64_t *out_byte_offset, double *out_actual_sec) {
    if (!ctx || ctx->sidx_count == 0) return -1;
    if (target_sec < 0.0) target_sec = 0.0;
    size_t best = 0;
    for (size_t i = 0; i < ctx->sidx_count; i++) {
        if (ctx->sidx[i].start_sec <= target_sec) {
            best = i;
        } else {
            break;
        }
    }
    if (out_byte_offset) *out_byte_offset = ctx->sidx[best].byte_offset;
    if (out_actual_sec)  *out_actual_sec  = ctx->sidx[best].start_sec;
    return 0;
}

/* Parse ISO 14496-1 descriptor length (up to 4 bytes, 7 bits each) */
static size_t parse_descr_len(const uint8_t *p, size_t avail, uint32_t *out_len) {
    uint32_t len = 0;
    size_t used = 0;
    while (used < avail && used < 4) {
        uint8_t b = p[used++];
        len = (len << 7) | (b & 0x7F);
        if ((b & 0x80) == 0) break;
    }
    *out_len = len;
    return used;
}

static void parse_esds(el_fmp4_ctx_t *ctx, const uint8_t *buf, size_t len) {
    /* Skip 4-byte FullBox version/flags */
    if (len < 6) return;
    size_t pos = 4;
    while (pos + 2 <= len) {
        uint8_t tag = buf[pos++];
        uint32_t dlen = 0;
        size_t lbytes = parse_descr_len(buf + pos, len - pos, &dlen);
        pos += lbytes;
        if (pos > len) break;

        if (tag == 0x03) {
            /* ES_DescrTag: 2 bytes ES_ID + 1 byte flags (+ optional fields) */
            if (pos + 3 > len) break;
            uint8_t flags = buf[pos + 2];
            pos += 3;
            if (flags & 0x80) {
                if (pos + 2 > len) break;
                pos += 2;
            }
            if (flags & 0x40) {
                if (pos >= len) break;
                size_t ulen = buf[pos];
                if (pos + 1 + ulen > len) break;
                pos += 1 + ulen;
            }
            if (flags & 0x20) {
                if (pos + 2 > len) break;
                pos += 2;
            }
        } else if (tag == 0x04) {
            /* DecoderConfigDescrTag: 13 bytes fixed header, followed by child descriptors */
            if (pos + 13 > len) break;
            pos += 13;
        } else if (tag == 0x05) {
            /* DecSpecificInfoTag: AudioSpecificConfig */
            if (dlen >= 2 && pos + 2 <= len) {
                uint8_t b0 = buf[pos];
                uint8_t b1 = buf[pos + 1];
                uint8_t obj_type = (b0 >> 3) & 0x1F;
                uint8_t freq_idx = (uint8_t)(((b0 & 0x07) << 1) | ((b1 >> 7) & 0x01));
                uint8_t chan_cfg = (b1 >> 3) & 0x0F;
                /* ADTS profile = objectType - 1; for HE-AAC (5/29) base core is AAC-LC (1) */
                if (obj_type >= 1 && obj_type <= 4) {
                    ctx->adts_profile = (uint8_t)(obj_type - 1);
                } else {
                    ctx->adts_profile = 1; /* AAC-LC */
                }
                if (freq_idx < 13) ctx->freq_idx = freq_idx;
                if (chan_cfg >= 1 && chan_cfg <= 7) ctx->chan_cfg = chan_cfg;
                ctx->has_config = 1;
            }
            return;
        } else {
            if (dlen > len - pos) break;
            pos += dlen;
        }
    }
}

#define EL_FMP4_MAX_BOX_DEPTH 8

static void parse_moov_children(el_fmp4_ctx_t *ctx, const uint8_t *buf, size_t len, int depth) {
    if (depth > EL_FMP4_MAX_BOX_DEPTH) return;
    size_t pos = 0;
    while (pos + 8 <= len) {
        uint64_t bsz = rd32(buf + pos);
        uint32_t btype = rd32(buf + pos + 4);
        size_t hdr = 8;
        if (bsz == 1) {
            if (pos + 16 > len) break;
            bsz = rd64(buf + pos + 8);
            hdr = 16;
        } else if (bsz == 0) {
            bsz = len - pos;
        }
        if (bsz < hdr || bsz > len - pos) break;

        const uint8_t *payload = buf + pos + hdr;
        size_t plen = (size_t)(bsz - hdr);

        if (btype == fourcc('t','r','a','k') ||
            btype == fourcc('m','d','i','a') ||
            btype == fourcc('m','i','n','f') ||
            btype == fourcc('s','t','b','l') ||
            btype == fourcc('m','v','e','x')) {
            parse_moov_children(ctx, payload, plen, depth + 1);
        } else if (btype == fourcc('m','v','h','d')) {
            if (plen >= 20) {
                uint8_t ver = payload[0];
                if (ver == 0 && plen >= 20) {
                    uint32_t ts = rd32(payload + 12);
                    uint32_t dur = rd32(payload + 16);
                    if (ts > 0 && dur > 0) ctx->total_duration = (double)dur / (double)ts;
                } else if (ver == 1 && plen >= 32) {
                    uint32_t ts = rd32(payload + 20);
                    uint64_t dur = rd64(payload + 24);
                    if (ts > 0 && dur > 0) ctx->total_duration = (double)dur / (double)ts;
                }
            }
        } else if (btype == fourcc('t','r','e','x')) {
            /* FullBox(4) + track_ID(4) + def_desc_idx(4) + def_dur(4) + def_size(4) + def_flags(4) */
            if (plen >= 24) {
                ctx->trex_default_sample_size = rd32(payload + 16);
            }
        } else if (btype == fourcc('s','t','s','d')) {
            /* FullBox(4) + entry_count(4) + child sample entries (e.g. mp4a) */
            if (plen > 8) {
                parse_moov_children(ctx, payload + 8, plen - 8, depth + 1);
            }
        } else if (btype == fourcc('m','p','4','a')) {
            /* AudioSampleEntry: 28 bytes fixed header, then child boxes (esds) */
            if (plen > 28) {
                uint16_t ch = rd16(payload + 16);
                uint32_t sr = rd32(payload + 24) >> 16;
                if (ch >= 1 && ch <= 7 && !ctx->has_config) ctx->chan_cfg = (uint8_t)ch;
                if (sr > 0 && !ctx->has_config) {
                    for (uint8_t i = 0; i < 13; i++) {
                        if (k_aac_sample_rates[i] == sr) {
                            ctx->freq_idx = i;
                            break;
                        }
                    }
                }
                parse_moov_children(ctx, payload + 28, plen - 28, depth + 1);
            }
        } else if (btype == fourcc('e','s','d','s')) {
            parse_esds(ctx, payload, plen);
        }

        pos += (size_t)bsz;
    }
}

static void parse_sidx(el_fmp4_ctx_t *ctx, const uint8_t *buf, size_t len, uint64_t sidx_end_pos) {
    if (len < 12) return;
    uint8_t version = buf[0];
    uint32_t timescale = rd32(buf + 8);
    if (timescale == 0) return;

    size_t pos = 12;
    uint64_t earliest_pts = 0;
    uint64_t first_offset = 0;
    if (version == 0) {
        if (pos + 8 > len) return;
        earliest_pts = rd32(buf + pos);
        first_offset = rd32(buf + pos + 4);
        pos += 8;
    } else {
        if (pos + 16 > len) return;
        earliest_pts = rd64(buf + pos);
        first_offset = rd64(buf + pos + 8);
        pos += 16;
    }
    if (pos + 4 > len) return;
    uint16_t ref_count = rd16(buf + pos + 2);
    pos += 4;

    if (ref_count == 0 || pos + (size_t)ref_count * 12 > len) return;
    if (UINT64_MAX - sidx_end_pos < first_offset) return;

    el_sidx_entry_t *entries = (el_sidx_entry_t *)malloc(sizeof(el_sidx_entry_t) * ref_count);
    if (!entries) return;

    uint64_t cur_offset = sidx_end_pos + first_offset;
    uint64_t cur_time = earliest_pts;
    for (uint16_t i = 0; i < ref_count; i++) {
        uint32_t w0 = rd32(buf + pos);
        uint32_t subseg_dur = rd32(buf + pos + 4);
        pos += 12;
        uint32_t ref_size = w0 & 0x7FFFFFFFu;
        if (UINT64_MAX - cur_offset < ref_size || UINT64_MAX - cur_time < subseg_dur) {
            free(entries);
            return;
        }
        entries[i].byte_offset = cur_offset;
        entries[i].byte_size = ref_size;
        entries[i].start_sec = (double)cur_time / (double)timescale;
        entries[i].duration_sec = (double)subseg_dur / (double)timescale;
        cur_offset += ref_size;
        cur_time += subseg_dur;
    }

    free(ctx->sidx);
    ctx->sidx = entries;
    ctx->sidx_count = ref_count;

    double total = (double)cur_time / (double)timescale;
    if (total > ctx->total_duration) {
        ctx->total_duration = total;
    }
}

static void parse_moof(el_fmp4_ctx_t *ctx, const uint8_t *buf, size_t len) {
    ctx->sample_count = 0;
    ctx->sample_idx = 0;
    ctx->frame_filled = 0;

    uint32_t tfhd_def_size = ctx->trex_default_sample_size;

    size_t pos = 0;
    while (pos + 8 <= len) {
        uint64_t bsz = rd32(buf + pos);
        uint32_t btype = rd32(buf + pos + 4);
        size_t hdr = 8;
        if (bsz == 1) {
            if (pos + 16 > len) break;
            bsz = rd64(buf + pos + 8);
            hdr = 16;
        } else if (bsz == 0) {
            bsz = len - pos;
        }
        if (bsz < hdr || bsz > len - pos) break;

        if (btype == fourcc('t','r','a','f')) {
            const uint8_t *tbuf = buf + pos + hdr;
            size_t tlen = (size_t)(bsz - hdr);
            size_t tpos = 0;
            while (tpos + 8 <= tlen) {
                uint64_t csz = rd32(tbuf + tpos);
                uint32_t ctype = rd32(tbuf + tpos + 4);
                size_t chdr = 8;
                if (csz == 1) {
                    if (tpos + 16 > tlen) break;
                    csz = rd64(tbuf + tpos + 8);
                    chdr = 16;
                } else if (csz == 0) {
                    csz = tlen - tpos;
                }
                if (csz < chdr || csz > tlen - tpos) break;
                const uint8_t *cp = tbuf + tpos + chdr;
                size_t clen = (size_t)(csz - chdr);

                if (ctype == fourcc('t','f','h','d') && clen >= 8) {
                    uint32_t flags = rd32(cp) & 0x00FFFFFFu;
                    size_t off = 8; /* flags(4) + track_id(4) */
                    if (flags & 0x000001u) {
                        if (off + 8 > clen) { tpos += (size_t)csz; continue; }
                        off += 8; /* base_data_offset */
                    }
                    if (flags & 0x000002u) {
                        if (off + 4 > clen) { tpos += (size_t)csz; continue; }
                        off += 4; /* sample_description_index */
                    }
                    if (flags & 0x000008u) {
                        if (off + 4 > clen) { tpos += (size_t)csz; continue; }
                        off += 4; /* default_sample_duration */
                    }
                    if (flags & 0x000010u) {
                        if (off + 4 > clen) { tpos += (size_t)csz; continue; }
                        tfhd_def_size = rd32(cp + off);
                    }
                } else if (ctype == fourcc('t','r','u','n') && clen >= 8) {
                    uint32_t flags = rd32(cp) & 0x00FFFFFFu;
                    uint32_t scount = rd32(cp + 4);
                    size_t off = 8;
                    if (flags & 0x000001u) {
                        if (off + 4 > clen) { tpos += (size_t)csz; continue; }
                        off += 4; /* data_offset */
                    }
                    if (flags & 0x000004u) {
                        if (off + 4 > clen) { tpos += (size_t)csz; continue; }
                        off += 4; /* first_sample_flags */
                    }

                    size_t row_bytes = 0;
                    if (flags & 0x000100u) row_bytes += 4; /* sample_duration */
                    if (flags & 0x000200u) row_bytes += 4; /* sample_size */
                    if (flags & 0x000400u) row_bytes += 4; /* sample_flags */
                    if (flags & 0x000800u) row_bytes += 4; /* sample_composition_time_offset */

                    if (scount > 0 && scount <= 65536 &&
                        ctx->sample_count + scount <= 65536 &&
                        (uint64_t)scount * (uint64_t)row_bytes <= (uint64_t)(clen - off)) {
                        if (ctx->sample_count + scount > ctx->sample_cap) {
                            size_t ncap = ctx->sample_count + scount + 64;
                            uint32_t *narr = (uint32_t *)realloc(ctx->sample_sizes, ncap * sizeof(uint32_t));
                            if (!narr) return;
                            ctx->sample_sizes = narr;
                            ctx->sample_cap = ncap;
                        }
                        for (uint32_t i = 0; i < scount; i++) {
                            uint32_t ssz = tfhd_def_size;
                            if (flags & 0x000100u) off += 4;
                            if (flags & 0x000200u) {
                                ssz = rd32(cp + off);
                                off += 4;
                            }
                            if (flags & 0x000400u) off += 4;
                            if (flags & 0x000800u) off += 4;
                            ctx->sample_sizes[ctx->sample_count++] = ssz;
                        }
                    }
                }
                tpos += (size_t)csz;
            }
        }
        pos += (size_t)bsz;
    }
}

static inline void write_adts_header(const el_fmp4_ctx_t *ctx, uint8_t *hdr, uint32_t raw_size) {
    uint32_t flen = raw_size + 7;
    uint8_t profile = ctx->adts_profile & 0x03;
    uint8_t freq = ctx->freq_idx & 0x0F;
    uint8_t ch = ctx->chan_cfg & 0x07;
    hdr[0] = 0xFF;
    hdr[1] = 0xF1; /* MPEG-4, Layer 0, no CRC */
    hdr[2] = (uint8_t)((profile << 6) | (freq << 2) | ((ch >> 2) & 0x01));
    hdr[3] = (uint8_t)(((ch & 0x03) << 6) | ((flen >> 11) & 0x03));
    hdr[4] = (uint8_t)((flen >> 3) & 0xFF);
    hdr[5] = (uint8_t)(((flen & 0x07) << 5) | 0x1F);
    hdr[6] = 0xFC;
}

static void finish_buffered_box(el_fmp4_ctx_t *ctx) {
    if (ctx->box_type == fourcc('m','o','o','v')) {
        parse_moov_children(ctx, ctx->box_buf, ctx->box_buf_len, 0);
    } else if (ctx->box_type == fourcc('s','i','d','x')) {
        parse_sidx(ctx, ctx->box_buf, ctx->box_buf_len, ctx->box_end_pos);
    } else if (ctx->box_type == fourcc('m','o','o','f')) {
        parse_moof(ctx, ctx->box_buf, ctx->box_buf_len);
    }
    ctx->box_buf_len = 0;
}

int el_fmp4_feed(el_fmp4_ctx_t *ctx, const uint8_t *data, size_t len) {
    if (!ctx || (!data && len > 0)) return -1;
    size_t pos = 0;

    while (pos < len) {
        if (ctx->state == STATE_BOX_HEADER) {
            size_t need = 8 - ctx->hdr_pos;
            size_t take = (len - pos < need) ? (len - pos) : need;
            memcpy(ctx->hdr_buf + ctx->hdr_pos, data + pos, take);
            ctx->hdr_pos += take;
            pos += take;
            ctx->stream_pos += take;

            if (ctx->hdr_pos == 8) {
                uint32_t sz32 = rd32(ctx->hdr_buf);
                ctx->box_type = rd32(ctx->hdr_buf + 4);
                ctx->hdr_pos = 0;

                if (sz32 == 1) {
                    ctx->state = STATE_BOX_EXTSIZE;
                } else {
                    if (sz32 < 8) return -2;
                    ctx->box_payload_rem = (uint64_t)(sz32 - 8);
                    ctx->box_end_pos = ctx->stream_pos + ctx->box_payload_rem;
                    if (ctx->box_type == fourcc('m','o','o','v') ||
                        ctx->box_type == fourcc('s','i','d','x') ||
                        ctx->box_type == fourcc('m','o','o','f')) {
                        if (ctx->box_payload_rem > 4 * 1024 * 1024) return -3;
                        ctx->box_buf_len = 0;
                        ctx->state = STATE_BOX_BUFFER;
                    } else if (ctx->box_type == fourcc('m','d','a','t')) {
                        ctx->sample_idx = 0;
                        ctx->frame_filled = 0;
                        ctx->state = STATE_MDAT_STREAM;
                    } else {
                        ctx->state = STATE_BOX_SKIP;
                    }
                    if (ctx->box_payload_rem == 0) {
                        if (ctx->state == STATE_BOX_BUFFER) finish_buffered_box(ctx);
                        ctx->state = STATE_BOX_HEADER;
                    }
                }
            }
        } else if (ctx->state == STATE_BOX_EXTSIZE) {
            size_t need = 8 - ctx->hdr_pos;
            size_t take = (len - pos < need) ? (len - pos) : need;
            memcpy(ctx->hdr_buf + ctx->hdr_pos, data + pos, take);
            ctx->hdr_pos += take;
            pos += take;
            ctx->stream_pos += take;

            if (ctx->hdr_pos == 8) {
                uint64_t sz64 = rd64(ctx->hdr_buf);
                ctx->hdr_pos = 0;
                if (sz64 < 16) return -2;
                ctx->box_payload_rem = sz64 - 16;
                ctx->box_end_pos = ctx->stream_pos + ctx->box_payload_rem;
                if (ctx->box_type == fourcc('m','d','a','t')) {
                    ctx->sample_idx = 0;
                    ctx->frame_filled = 0;
                    ctx->state = STATE_MDAT_STREAM;
                } else {
                    ctx->state = STATE_BOX_SKIP;
                }
            }
        } else if (ctx->state == STATE_BOX_BUFFER) {
            uint64_t avail = (uint64_t)(len - pos);
            size_t take = (avail < ctx->box_payload_rem) ? (size_t)avail : (size_t)ctx->box_payload_rem;
            if (ctx->box_buf_len + take > ctx->box_buf_cap) {
                size_t ncap = ctx->box_buf_len + take + 4096;
                uint8_t *nb = (uint8_t *)realloc(ctx->box_buf, ncap);
                if (!nb) return -4;
                ctx->box_buf = nb;
                ctx->box_buf_cap = ncap;
            }
            memcpy(ctx->box_buf + ctx->box_buf_len, data + pos, take);
            ctx->box_buf_len += take;
            pos += take;
            ctx->stream_pos += take;
            ctx->box_payload_rem -= take;
            if (ctx->box_payload_rem == 0) {
                finish_buffered_box(ctx);
                ctx->state = STATE_BOX_HEADER;
            }
        } else if (ctx->state == STATE_BOX_SKIP) {
            uint64_t avail = (uint64_t)(len - pos);
            size_t take = (avail < ctx->box_payload_rem) ? (size_t)avail : (size_t)ctx->box_payload_rem;
            pos += take;
            ctx->stream_pos += take;
            ctx->box_payload_rem -= take;
            if (ctx->box_payload_rem == 0) {
                ctx->state = STATE_BOX_HEADER;
            }
        } else if (ctx->state == STATE_MDAT_STREAM) {
            if (ctx->sample_idx >= ctx->sample_count) {
                /* Any trailing padding bytes in mdat */
                uint64_t avail = (uint64_t)(len - pos);
                size_t take = (avail < ctx->box_payload_rem) ? (size_t)avail : (size_t)ctx->box_payload_rem;
                pos += take;
                ctx->stream_pos += take;
                ctx->box_payload_rem -= take;
                if (ctx->box_payload_rem == 0) ctx->state = STATE_BOX_HEADER;
                continue;
            }

            uint32_t fsize = ctx->sample_sizes[ctx->sample_idx];
            if (fsize == 0 || fsize > 65535) {
                return -5;
            }

            if (fsize + 7 > ctx->frame_cap) {
                size_t ncap = (size_t)fsize + 256;
                uint8_t *nb = (uint8_t *)realloc(ctx->frame_buf, ncap);
                if (!nb) return -4;
                ctx->frame_buf = nb;
                ctx->frame_cap = ncap;
            }

            size_t need = (size_t)fsize - ctx->frame_filled;
            uint64_t avail = (uint64_t)(len - pos);
            if (avail > ctx->box_payload_rem) avail = ctx->box_payload_rem;
            size_t take = (avail < need) ? (size_t)avail : need;

            memcpy(ctx->frame_buf + 7 + ctx->frame_filled, data + pos, take);
            ctx->frame_filled += take;
            pos += take;
            ctx->stream_pos += take;
            ctx->box_payload_rem -= take;

            if (ctx->frame_filled == (size_t)fsize) {
                write_adts_header(ctx, ctx->frame_buf, fsize);
                if (ctx->on_frame) {
                    ctx->on_frame(ctx->frame_buf, (size_t)fsize + 7, ctx->user_data);
                }
                ctx->sample_idx++;
                ctx->frame_filled = 0;
            }

            if (ctx->box_payload_rem == 0) {
                ctx->state = STATE_BOX_HEADER;
            }
        }
    }

    return 0;
}
