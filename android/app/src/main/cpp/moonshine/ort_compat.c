// Moonshine 0.1.5 imports the ORT 1.23.2 ELF symbol versions. ORT's
// versioned C API tables preserve that API in newer runtimes.
struct OrtApiBase;
struct OrtSessionOptions;
struct OrtStatus;
extern const struct OrtApiBase *OrtGetApiBase_next(void);
extern struct OrtStatus *OrtCpu_next(struct OrtSessionOptions *, int);
__asm__(".symver OrtGetApiBase_next,OrtGetApiBase@VERS_1.28.0");
__asm__(".symver OrtCpu_next,OrtSessionOptionsAppendExecutionProvider_CPU@VERS_1.28.0");
const struct OrtApiBase *OrtGetApiBase(void) {
    return OrtGetApiBase_next();
}
struct OrtStatus *OrtSessionOptionsAppendExecutionProvider_CPU(struct OrtSessionOptions *options, int use_arena) {
    return OrtCpu_next(options, use_arena);
}
