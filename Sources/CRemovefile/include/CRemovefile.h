// removefile(3) lives in an explicit Darwin submodule that Foundation doesn't re-export on every SDK,
// so this header gives Swift one import that works with each Xcode version.
#include <removefile.h>
