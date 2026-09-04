local errors = require "../errors"
local types = require "../types"

type Array<T> = { T }

export type ProfileBase<T = any> = types.ProfileBase<T>
export type LoadOptions = types.LoadOptions
export type MigrationsResult = types.MigrationsResult

local common = {}

--- Throws a `profile_closed` error right away when the profile is closed. Not
--- strictly needed (the closed mutex rejects the call anyway) but it fails
--- before queueing on the mutex.
function common.assert_open(self: ProfileBase)
	if not self.open then
		error(errors.closed(self), 0)
	end
end

--- Applies the declared migrations not yet in `applied` (in order). Pure, so it
--- is safe inside an update transform. Fails (a `migration_mismatch` error in
--- `err`) when the record's applied list does not prefix-match the declared
--- list. An error thrown by a migration's `apply` propagates as is.
function common.apply_migrations(
	key: string,
	data: any,
	applied: { string },
	migrations: Array<types.Migration>
): MigrationsResult
	local applied_count = #applied

	if applied_count > #migrations then
		return {
			applied = false,
			success = false,
			err = errors.migration_mismatch(key, {
				applied = applied,
				declared = common.all_migration_names(migrations),
			}),
			new_migrations = applied,
		}
	end

	for index = 1, applied_count do
		local expected = migrations[index].name
		local actual = applied[index]
		if actual ~= expected then
			return {
				applied = false,
				success = false,
				err = errors.migration_mismatch(key, {
					index = index,
					expected = expected,
					actual = actual,
					applied = applied,
					declared = common.all_migration_names(migrations),
				}),
				new_migrations = applied,
			}
		end
	end

	if applied_count == #migrations then
		return { applied = false, success = true, result = data, new_migrations = applied }
	end

	local new_migrations = table.clone(applied)
	for index = applied_count + 1, #migrations do
		local migration = migrations[index]
		data = migration.apply(data)
		table.insert(new_migrations, migration.name)
	end

	return { applied = true, success = true, result = data, new_migrations = new_migrations }
end

--- Names of every declared migration; what a fresh template counts as having applied.
function common.all_migration_names(migrations: Array<types.Migration>): { string }
	local names = table.create(#migrations) :: { string }
	for index, migration in migrations do
		names[index] = migration.name
	end
	return names
end

function common.is_lock_owned(record: types.DataRecord?, job_id: string)
	if not record then
		return false
	end

	local lock = record.lock
	if not lock then
		return false
	end

	return lock.id == job_id
end

function common.is_locked_for(record: types.DataRecord?, job_id: string, now: number)
	if not record then
		return false
	end
	local lock = record.lock
	if not lock then
		return false
	end

	return lock.id ~= job_id and lock.expires > now
end

function common.has_lock(record: types.DataRecord?)
	if not record then
		return false
	end
	return not not record.lock
end

return common
