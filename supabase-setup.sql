-- ============================================================
-- Half Kweah 多家庭改造脚本
-- 用法:Supabase 后台 → SQL Editor → 新建查询,整段粘贴,点 Run。
-- 可以重复运行(幂等),已有数据会自动迁移为第一个家庭。
-- 运行完记得在后台做两件事(脚本做不了):
--   1. Authentication → Sign In / Providers → Email:
--      开启 "Enable Email Signups",关闭 "Confirm email"
--   2. 无需其他改动,前端新版页面即可注册使用
-- ============================================================

-- ---------- 1. 家庭表 ----------
create table if not exists public.families (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default '我们家',
  invite_code text not null unique,
  legacy      boolean not null default false,   -- 创始家庭(兼容根目录老照片)
  created_at  timestamptz not null default now()
);

-- ---------- 2. 账号 ↔ 家庭 关系表(一个账号属于一个家庭) ----------
create table if not exists public.family_members (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  joined_at timestamptz not null default now()
);

-- ---------- 3. 工具函数:当前登录账号所属的家庭 id ----------
create or replace function public.my_family_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select family_id from public.family_members where user_id = auth.uid()
$$;
revoke all on function public.my_family_id() from public, anon;
grant execute on function public.my_family_id() to authenticated;

-- ---------- 4. 迁移现有数据(id='main' 的旧行 → 创始家庭) ----------
do $$
declare fid uuid; code text;
begin
  if exists (select 1 from public.family_state where id = 'main') then
    code := upper(substr(md5(random()::text), 1, 6));
    insert into public.families(name, invite_code, legacy)
      values ('Half Kweah', code, true)
      returning id into fid;
    insert into public.family_state(id, data, device, updated_at)
      select fid::text, data, device, updated_at
      from public.family_state where id = 'main';
    delete from public.family_state where id = 'main';
    -- 现有的所有账号都归入创始家庭(目前库里只有你们家的账号)
    insert into public.family_members(user_id, family_id)
      select id, fid from auth.users
      on conflict (user_id) do nothing;
    raise notice '已迁移现有数据。你们家的邀请码是: %', code;
  end if;
end $$;

-- ---------- 5. RLS:每家只能读写自己那一行 ----------
alter table public.family_state   enable row level security;
alter table public.families       enable row level security;
alter table public.family_members enable row level security;

-- 清掉 family_state 上的旧策略(旧策略是"所有登录用户可读写",必须删)
do $$
declare p record;
begin
  for p in select policyname from pg_policies
           where schemaname = 'public' and tablename = 'family_state' loop
    execute format('drop policy %I on public.family_state', p.policyname);
  end loop;
end $$;

create policy "family read own state"   on public.family_state
  for select to authenticated using (id = public.my_family_id()::text);
create policy "family insert own state" on public.family_state
  for insert to authenticated with check (id = public.my_family_id()::text);
create policy "family update own state" on public.family_state
  for update to authenticated
  using (id = public.my_family_id()::text)
  with check (id = public.my_family_id()::text);

drop policy if exists "member read own family" on public.families;
create policy "member read own family" on public.families
  for select to authenticated using (id = public.my_family_id());

drop policy if exists "member read own membership" on public.family_members;
create policy "member read own membership" on public.family_members
  for select to authenticated
  using (user_id = auth.uid() or family_id = public.my_family_id());

-- ---------- 6. RPC:创建家庭 / 凭邀请码加入 / 查询我的家庭 ----------
create or replace function public.create_family(fam_name text)
returns json
language plpgsql security definer set search_path = public
as $$
declare code text; fid uuid; tries int := 0;
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  if exists (select 1 from family_members where user_id = auth.uid()) then
    raise exception '你已经加入了一个家庭';
  end if;
  loop
    code := upper(substr(md5(random()::text), 1, 6));
    begin
      insert into families(name, invite_code)
        values (coalesce(nullif(trim(fam_name), ''), '我们家'), code)
        returning id into fid;
      exit;
    exception when unique_violation then
      tries := tries + 1;
      if tries > 5 then raise; end if;
    end;
  end loop;
  insert into family_members(user_id, family_id) values (auth.uid(), fid);
  insert into family_state(id, data, device, updated_at)
    values (fid::text, '{}'::jsonb, '', now())
    on conflict (id) do nothing;
  return json_build_object('family_id', fid, 'name',
    (select name from families where id = fid), 'invite_code', code, 'legacy', false);
end $$;

create or replace function public.join_family(code text)
returns json
language plpgsql security definer set search_path = public
as $$
declare fid uuid; fname text; fcode text; fleg boolean;
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  if exists (select 1 from family_members where user_id = auth.uid()) then
    raise exception '你已经加入了一个家庭';
  end if;
  select id, name, invite_code, legacy into fid, fname, fcode, fleg
    from families where invite_code = upper(trim(code));
  if fid is null then raise exception '邀请码不对,请再核对一下'; end if;
  insert into family_members(user_id, family_id) values (auth.uid(), fid);
  return json_build_object('family_id', fid, 'name', fname, 'invite_code', fcode, 'legacy', fleg);
end $$;

create or replace function public.my_family()
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object('family_id', f.id, 'name', f.name,
                           'invite_code', f.invite_code, 'legacy', f.legacy)
  from families f
  join family_members m on m.family_id = f.id
  where m.user_id = auth.uid()
$$;

revoke all on function public.create_family(text) from public, anon;
revoke all on function public.join_family(text)   from public, anon;
revoke all on function public.my_family()         from public, anon;
grant execute on function public.create_family(text) to authenticated;
grant execute on function public.join_family(text)   to authenticated;
grant execute on function public.my_family()          to authenticated;

-- ---------- 7. 相册存储:照片按家庭文件夹隔离 ----------
-- 清掉 family-photos 桶的旧策略(旧策略是"所有登录用户可读写")
do $$
declare p record;
begin
  for p in select policyname from pg_policies
           where schemaname = 'storage' and tablename = 'objects'
             and (coalesce(qual,'') like '%family-photos%'
               or coalesce(with_check,'') like '%family-photos%') loop
    execute format('drop policy %I on storage.objects', p.policyname);
  end loop;
end $$;

-- 新照片一律传到 <family_id>/ 文件夹下;创始家庭额外能看到根目录的老照片
create policy "fam photos select" on storage.objects
  for select to authenticated
  using (bucket_id = 'family-photos' and (
    (storage.foldername(name))[1] = public.my_family_id()::text
    or (array_length(storage.foldername(name), 1) is null
        and exists (select 1 from public.families f
                    where f.id = public.my_family_id() and f.legacy))
  ));

create policy "fam photos insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'family-photos'
    and (storage.foldername(name))[1] = public.my_family_id()::text);

create policy "fam photos delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'family-photos' and (
    (storage.foldername(name))[1] = public.my_family_id()::text
    or (array_length(storage.foldername(name), 1) is null
        and exists (select 1 from public.families f
                    where f.id = public.my_family_id() and f.legacy))
  ));

-- 完成。回到 App 刷新页面即可。
