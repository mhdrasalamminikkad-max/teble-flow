begin;
-- Existing duplicate usernames are retained; their owners must rename them in Platform Admin.
-- Prevent new conflicts across restaurants, including case-only variants.
create or replace function tableflow_pilot.unique_staff_username() returns trigger language plpgsql set search_path=pg_catalog,tableflow_pilot as $$begin
 if tg_op='UPDATE' and new.username=old.username then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended(lower(trim(new.username)),17));
 if exists(select 1 from tableflow_pilot.staff where lower(trim(username))=lower(trim(new.username)) and id<>new.id) then raise exception 'This username is already taken. Choose a unique username.';end if;
 return new;
end$$;
drop trigger if exists tfp_unique_username on tableflow_pilot.staff;
create trigger tfp_unique_username before insert or update of username on tableflow_pilot.staff for each row execute function tableflow_pilot.unique_staff_username();
create or replace function public.tfp_staff_login(p_username text,p_password text) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;t text;n integer;begin
 select count(*) into n from tableflow_pilot.staff a join tableflow_pilot.restaurants r on r.id=a.restaurant where lower(a.username)=lower(trim(p_username)) and a.active and r.active;
 if n>1 then return jsonb_build_object('error','This username is shared by multiple accounts. Ask your platform admin to assign a unique username.');end if;
 select a.* into s from tableflow_pilot.staff a join tableflow_pilot.restaurants r on r.id=a.restaurant where lower(a.username)=lower(trim(p_username)) and a.active and r.active for update of a;
 if s.id is null then return jsonb_build_object('error','Username or password is incorrect');end if;
 if s.locked_until>now() then return jsonb_build_object('error','Too many attempts. Try again in five minutes.');end if;
 if p_password is null or octet_length(p_password)>72 or tableflow_pilot.pin_hash(p_password,s.pin_hash)<>s.pin_hash then
 update tableflow_pilot.staff set failures=case when failures>=4 then 0 else failures+1 end,locked_until=case when failures>=4 then now()+interval '5 minutes' else null end where id=s.id;
 return jsonb_build_object('error','Username or password is incorrect');end if;
 update tableflow_pilot.staff set failures=0,locked_until=null where id=s.id;
 t=tableflow_pilot.token();insert into tableflow_pilot.staff_sessions(token_hash,staff,expires) values(tableflow_pilot.hash(t),s.id,'infinity');
 return jsonb_build_object('token',t,'username',s.username,'role',s.role);
end$$;
revoke all on function tableflow_pilot.unique_staff_username() from public,anon,authenticated;
revoke all on function public.tfp_staff_login(text,text) from public;
grant execute on function public.tfp_staff_login(text,text) to anon,authenticated;
create or replace function public.tfp_health() returns jsonb language sql security definer set search_path=pg_catalog as $$select jsonb_build_object('version',7)$$;
commit;
