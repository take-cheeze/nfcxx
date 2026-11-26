/*
** mruby/require.h - require for the features this build provides (mrbgems/mruby-require).
**
** There are no files to load. A feature is a name the build provides: every gem of the build registers its name, and
** the name without its mruby- prefix (the generated gem table, tasks/mrbgems.rake). require returns false for a feature
** that is provided (it is already loaded, as CRuby returns false for a loaded feature), and raises LoadError otherwise.
** The loaded features are the array $LOADED_FEATURES.
**
** rb_require is the C form (CRuby's rb_require, with the state passed first): the cext2mrbgem converter maps a literal
** feature name to it.
*/
#ifndef MRUBY_REQUIRE_H
#define MRUBY_REQUIRE_H

#include <mruby.h>

#ifdef __cplusplus
extern "C" {
#endif

/* registers name as a provided feature (once) */
MRB_API void mrb_require_provide(mrb_state *mrb, const char *name);
/* require name: false when it is provided; LoadError otherwise */
MRB_API mrb_value rb_require(mrb_state *mrb, const char *name);

#ifdef __cplusplus
}
#endif

#endif
