#ifndef EL_FMP4_ADTS_H
#define EL_FMP4_ADTS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t byte_offset;
    uint32_t byte_size;
    double   start_sec;
    double   duration_sec;
} el_sidx_entry_t;

typedef void (*el_adts_frame_cb)(const uint8_t *adts_data, size_t len, void *user_data);

typedef struct el_fmp4_ctx el_fmp4_ctx_t;

el_fmp4_ctx_t *el_fmp4_create(el_adts_frame_cb on_frame, void *user_data);
void           el_fmp4_destroy(el_fmp4_ctx_t *ctx);

/* Feed raw bytes from the fMP4 stream (ftyp/moov/sidx/moof/mdat). Returns 0 on ok, <0 on error. */
int            el_fmp4_feed(el_fmp4_ctx_t *ctx, const uint8_t *data, size_t len);

/* Reset box/mdat state for seeking to a new sidx byte offset while keeping moov audio config & sidx table. */
void           el_fmp4_reset_for_seek(el_fmp4_ctx_t *ctx, uint64_t new_stream_offset);

/* Query parsed metadata */
int            el_fmp4_has_config(const el_fmp4_ctx_t *ctx);
uint32_t       el_fmp4_sample_rate(const el_fmp4_ctx_t *ctx);
uint8_t        el_fmp4_channels(const el_fmp4_ctx_t *ctx);
double         el_fmp4_total_duration(const el_fmp4_ctx_t *ctx);
uint64_t       el_fmp4_stream_offset(const el_fmp4_ctx_t *ctx);

/* Query sidx segments for seeking */
size_t         el_fmp4_sidx_count(const el_fmp4_ctx_t *ctx);
const el_sidx_entry_t *el_fmp4_sidx_entry(const el_fmp4_ctx_t *ctx, size_t idx);
int            el_fmp4_find_seek_offset(const el_fmp4_ctx_t *ctx, double target_sec,
                                        uint64_t *out_byte_offset, double *out_actual_sec);

#ifdef __cplusplus
}
#endif

#endif /* EL_FMP4_ADTS_H */
