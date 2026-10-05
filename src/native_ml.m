// CoreML for the extractors (docs/30 §Stems): load a compiled model
// (.mlmodelc) and run it on named float32 tensors. Any thread but the
// audio thread; a model is used by one thread at a time.

#import <CoreML/CoreML.h>
#include <string.h>

static void set_err(char *err, int err_len, NSString *msg) {
    if (!err || err_len <= 0) return;
    const char *s = msg ? msg.UTF8String : "unknown error";
    strncpy(err, s ? s : "unknown error", (size_t)err_len - 1);
    err[err_len - 1] = 0;
}

void *slab_ml_load(const char *path, char *err, int err_len) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        MLModelConfiguration *cfg = [MLModelConfiguration new];
        cfg.computeUnits = MLComputeUnitsAll;
        NSError *e = nil;
        MLModel *m = [MLModel modelWithContentsOfURL:url configuration:cfg error:&e];
        if (!m) {
            set_err(err, err_len, e.localizedDescription);
            return NULL;
        }
        return (__bridge_retained void *)m;
    }
}

void slab_ml_free(void *model) {
    if (model) {
        MLModel *m = (__bridge_transfer MLModel *)model;
        (void)m;
    }
}

// Copy a float32 array out, whatever its strides, into `out` (C order).
static int copy_out(MLMultiArray *a, float *out, long count) {
    if (a.dataType != MLMultiArrayDataTypeFloat32) return 0;
    NSArray<NSNumber *> *shape = a.shape;
    NSArray<NSNumber *> *strides = a.strides;
    NSInteger rank = (NSInteger)shape.count;
    long total = 1;
    for (NSInteger i = 0; i < rank; i++) total *= shape[i].longValue;
    if (total != count) return 0;
    __block int ok = 1;
    [a getBytesWithHandler:^(const void *bytes, NSInteger size) {
        (void)size;
        const float *src = (const float *)bytes;
        long idx[8] = {0};
        long inner = shape[rank - 1].longValue;
        long inner_stride = strides[rank - 1].longValue;
        long rows = total / inner;
        for (long row = 0; row < rows; row++) {
            long off = 0;
            for (NSInteger d = 0; d < rank - 1; d++) off += idx[d] * strides[d].longValue;
            float *dst = out + row * inner;
            if (inner_stride == 1) memcpy(dst, src + off, (size_t)inner * sizeof(float));
            else for (long k = 0; k < inner; k++) dst[k] = src[off + k * inner_stride];
            for (NSInteger d = rank - 2; d >= 0; d--) {
                if (++idx[d] < shape[d].longValue) break;
                idx[d] = 0;
            }
        }
    }];
    return ok;
}

// Inputs: `n_in` named tensors, `ranks[i]` dims each, their shapes one
// after another in `shapes`. Outputs: copied into `out_data[i]`, which
// holds `out_counts[i]` floats. 0 on success, else `err` says why.
int slab_ml_predict(void *model, int n_in, const char **in_names, const float **in_data, const int *ranks, const long *shapes,
                    int n_out, const char **out_names, float **out_data, const long *out_counts, char *err, int err_len) {
    @autoreleasepool {
        MLModel *m = (__bridge MLModel *)model;
        NSMutableDictionary<NSString *, MLFeatureValue *> *feats = [NSMutableDictionary dictionary];
        long at = 0;
        for (int i = 0; i < n_in; i++) {
            NSMutableArray<NSNumber *> *shape = [NSMutableArray array];
            NSMutableArray<NSNumber *> *strides = [NSMutableArray array];
            for (int d = 0; d < ranks[i]; d++) [shape addObject:@(shapes[at + d])];
            long s = 1;
            for (int d = ranks[i] - 1; d >= 0; d--) {
                [strides insertObject:@(s) atIndex:0];
                s *= shapes[at + d];
            }
            at += ranks[i];
            NSError *e = nil;
            MLMultiArray *arr = [[MLMultiArray alloc] initWithDataPointer:(void *)in_data[i] shape:shape dataType:MLMultiArrayDataTypeFloat32
                                                                 strides:strides deallocator:nil error:&e];
            if (!arr) {
                set_err(err, err_len, e.localizedDescription);
                return 1;
            }
            feats[[NSString stringWithUTF8String:in_names[i]]] = [MLFeatureValue featureValueWithMultiArray:arr];
        }
        NSError *e = nil;
        MLDictionaryFeatureProvider *in = [[MLDictionaryFeatureProvider alloc] initWithDictionary:feats error:&e];
        if (!in) {
            set_err(err, err_len, e.localizedDescription);
            return 1;
        }
        id<MLFeatureProvider> out = [m predictionFromFeatures:in error:&e];
        if (!out) {
            set_err(err, err_len, e.localizedDescription);
            return 1;
        }
        for (int i = 0; i < n_out; i++) {
            MLFeatureValue *v = [out featureValueForName:[NSString stringWithUTF8String:out_names[i]]];
            if (!v || !v.multiArrayValue || !copy_out(v.multiArrayValue, out_data[i], out_counts[i])) {
                set_err(err, err_len, [NSString stringWithFormat:@"output %s missing or not float32 of the expected size", out_names[i]]);
                return 1;
            }
        }
        return 0;
    }
}
