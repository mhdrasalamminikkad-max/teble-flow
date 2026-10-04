-- Run after 004_restaurant_admin.sql in the trusted Supabase SQL Editor.
-- Creates the first admin only. Never resets or overwrites an existing login.
-- Save the returned password privately; it cannot be retrieved later.
begin;
create temporary table tfp_new_admin_credentials(username text,password text) on commit preserve rows;
do $$declare pw text;begin
 if exists(select 1 from tableflow_pilot.platform_admins) then
 raise exception 'An admin already exists. This script does not reset passwords.';end if;
 pw='Tf9!'||replace(gen_random_uuid()::text,'-','');
 insert into tableflow_pilot.platform_admins(username,password_hash) values('admin',tableflow_pilot.pin_hash(pw));
 insert into tfp_new_admin_credentials values('admin',pw);
end$$;
commit;
select username,password from tfp_new_admin_credentials;
