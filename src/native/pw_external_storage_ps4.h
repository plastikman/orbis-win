/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef PW_EXTERNAL_STORAGE_PS4_H
#define PW_EXTERNAL_STORAGE_PS4_H

typedef void (*PwExternalStorageLog)(const char *line);

void pw_external_storage_set_log(PwExternalStorageLog log);
int pw_external_storage_enable_if_requested(const char *data_root);
void pw_external_storage_prepare_prefix(const char *prefix);
int pw_external_storage_restore_for_loadexec(void);
void pw_external_storage_resume_after_failed_loadexec(int was_enabled);
void pw_external_storage_restore(const char *reason);

#endif
