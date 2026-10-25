-- 罰單加「類型」欄位：而家全部都係 fine（罰單），之後新增其他錢的類型時只要加新的值，不用改表格結構
alter table public.tickets add column if not exists kind text not null default 'fine';
