-- ════════════════════════════════════════════════════════════════
-- GMT Systems — transfer_setup.sql
-- نظام النقل الداخلي بين الفروع + تعديلات الجداول الموجودة
-- يونيو 2026
-- ════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════
-- 1. جدول رأس فاتورة النقل
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.branch_transfers (
  id                UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  transfer_number   TEXT        NOT NULL UNIQUE,
  from_branch       TEXT        NOT NULL,
  from_branch_name  TEXT        NOT NULL,
  to_branch         TEXT        NOT NULL,
  to_branch_name    TEXT        NOT NULL,
  status            TEXT        NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','received','cancelled')),
  -- pending  = أُنشئت، خُصم من المُرسِل، لم تصل بعد
  -- received = أُكِّد الاستلام، أُضيف للمستلم
  -- cancelled = مُلغاة، أُعيدت الكميات
  notes             TEXT,
  created_by        TEXT,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  received_at       TIMESTAMPTZ,
  received_by       TEXT,
  signature_url     TEXT,
  telegram_sent     BOOLEAN     DEFAULT FALSE,
  is_locked         BOOLEAN     DEFAULT TRUE   -- مقفولة فور الحفظ
);

-- ════════════════════════════════════════════════════════════════
-- 2. جدول بنود النقل
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.transfer_items (
  id            UUID          DEFAULT gen_random_uuid() PRIMARY KEY,
  transfer_id   UUID          REFERENCES branch_transfers(id) ON DELETE CASCADE,
  product_id    TEXT          NOT NULL,
  product_name  TEXT          NOT NULL,
  barcode       TEXT,
  image_url     TEXT,
  qty           INTEGER       NOT NULL CHECK (qty > 0),
  unit_cost     NUMERIC(10,2) DEFAULT 0,   -- سعر الجملة/التكلفة
  sale_price    NUMERIC(10,2) DEFAULT 0,   -- سعر المبيع المتوقع
  notes         TEXT
);

-- ════════════════════════════════════════════════════════════════
-- 3. جدول إشعارات الفروع
-- ════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.branch_notifications (
  id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  branch_key  TEXT        NOT NULL,
  type        TEXT        NOT NULL
              CHECK (type IN ('new_transfer','transfer_received','transfer_cancelled')),
  ref_id      UUID,
  message     TEXT        NOT NULL,
  is_read     BOOLEAN     DEFAULT FALSE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ════════════════════════════════════════════════════════════════
-- 4. تعديلات على جدول gmt_orders
-- ════════════════════════════════════════════════════════════════

-- منع ربط نفس الأوردر بأكثر من فاتورة (UNIQUE يمنع التضارب)
ALTER TABLE public.gmt_orders
  ADD COLUMN IF NOT EXISTS linked_invoice_id TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS is_locked         BOOLEAN DEFAULT FALSE;

-- حقول الإعداد (prepared) — عند إنشاء الفاتورة المرتبطة
ALTER TABLE public.gmt_orders
  ADD COLUMN IF NOT EXISTS prepared_by     TEXT,
  ADD COLUMN IF NOT EXISTS prepared_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS prepared_branch TEXT;

-- إضافة حالة 'prepared' للـ status (بين pending وshipped)
-- أولاً: احذف الـ constraint القديم إن وُجد
ALTER TABLE public.gmt_orders
  DROP CONSTRAINT IF EXISTS gmt_orders_status_check;

-- أضف الـ constraint الجديد مع 'prepared'
ALTER TABLE public.gmt_orders
  ADD CONSTRAINT gmt_orders_status_check
  CHECK (status IN ('pending','prepared','shipped','delivered','completed'));

-- ════════════════════════════════════════════════════════════════
-- 5. حقل in_transit في products
-- ════════════════════════════════════════════════════════════════
-- مثال: {"haleb": 3, "damascus": 5}
-- يعني 3 قطع خرجت من حلب ولم تصل بعد
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS in_transit JSONB DEFAULT '{}';

-- ════════════════════════════════════════════════════════════════
-- 6. ترقيم فواتير النقل التلقائي
-- ════════════════════════════════════════════════════════════════
CREATE SEQUENCE IF NOT EXISTS transfer_seq START 1;

CREATE OR REPLACE FUNCTION next_transfer_number()
RETURNS TEXT AS $$
  SELECT 'TRF-' ||
         TO_CHAR(NOW(), 'YYYY-MM') || '-' ||
         LPAD(nextval('transfer_seq')::TEXT, 6, '0');
$$ LANGUAGE SQL;

-- ════════════════════════════════════════════════════════════════
-- 7. RPC آمن لخصم المخزون (يمنع الرصيد السالب عند التزامن)
-- ════════════════════════════════════════════════════════════════
-- ملاحظة: هذا الـ RPC يعمل على أعمدة مباشرة في جدول products
-- (homs, haleb, daraa, kurani, sarmada, fakhouri وليس JSONB data)
-- لأن نظام GMT يخزن الكميات كأعمدة منفصلة

CREATE OR REPLACE FUNCTION deduct_branch_stock(
  p_product_id TEXT,
  p_branch_key TEXT,
  p_qty        INTEGER
) RETURNS BOOLEAN AS $$
DECLARE
  current_qty  INTEGER;
  query_text   TEXT;
BEGIN
  -- قفل الصف للقراءة الآمنة
  EXECUTE format(
    'SELECT COALESCE(%I, 0) FROM products WHERE id = $1 FOR UPDATE',
    p_branch_key
  ) INTO current_qty USING p_product_id;

  IF current_qty IS NULL OR current_qty < p_qty THEN
    RETURN FALSE;
  END IF;

  EXECUTE format(
    'UPDATE products SET %I = %I - $1 WHERE id = $2',
    p_branch_key, p_branch_key
  ) USING p_qty, p_product_id;

  RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC لإضافة كمية لفرع (عند تأكيد الاستلام)
CREATE OR REPLACE FUNCTION add_branch_stock(
  p_product_id TEXT,
  p_branch_key TEXT,
  p_qty        INTEGER
) RETURNS BOOLEAN AS $$
BEGIN
  EXECUTE format(
    'UPDATE products SET %I = COALESCE(%I, 0) + $1 WHERE id = $2',
    p_branch_key, p_branch_key
  ) USING p_qty, p_product_id;
  RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ════════════════════════════════════════════════════════════════
-- 8. فهارس الأداء
-- ════════════════════════════════════════════════════════════════
CREATE INDEX IF NOT EXISTS idx_bt_status   ON branch_transfers(status);
CREATE INDEX IF NOT EXISTS idx_bt_from     ON branch_transfers(from_branch);
CREATE INDEX IF NOT EXISTS idx_bt_to       ON branch_transfers(to_branch);
CREATE INDEX IF NOT EXISTS idx_bt_created  ON branch_transfers(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ti_tid      ON transfer_items(transfer_id);
CREATE INDEX IF NOT EXISTS idx_bn_branch   ON branch_notifications(branch_key, is_read);
CREATE INDEX IF NOT EXISTS idx_orders_prep ON gmt_orders(prepared_branch);

-- ════════════════════════════════════════════════════════════════
-- 9. Row Level Security — تفعيل على الجداول الجديدة
-- ════════════════════════════════════════════════════════════════
ALTER TABLE public.branch_transfers     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transfer_items       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branch_notifications ENABLE ROW LEVEL SECURITY;

-- سياسة مفتوحة مؤقتة (الوصول بالـ anon key من الواجهة)
-- عدّلها لاحقاً حسب أدوار المستخدمين
CREATE POLICY "allow_all_branch_transfers"
  ON public.branch_transfers FOR ALL
  USING (true) WITH CHECK (true);

CREATE POLICY "allow_all_transfer_items"
  ON public.transfer_items FOR ALL
  USING (true) WITH CHECK (true);

CREATE POLICY "allow_all_branch_notifications"
  ON public.branch_notifications FOR ALL
  USING (true) WITH CHECK (true);

-- ════════════════════════════════════════════════════════════════
-- 10. إضافة updated_at لـ products (للمزامنة الذكية في gmt-cache.js)
-- ════════════════════════════════════════════════════════════════
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Trigger لتحديث updated_at تلقائياً
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_products_updated_at ON public.products;
CREATE TRIGGER trg_products_updated_at
  BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ════════════════════════════════════════════════════════════════
-- ملاحظات تنفيذية
-- ════════════════════════════════════════════════════════════════
-- بعد تشغيل هذا الملف في Supabase SQL Editor:
-- 1. أنشئ Bucket يدوياً من Storage UI:
--    الاسم: transfer-signatures
--    النوع: Private (للتحكم بالوصول)
--    الحجم الأقصى: 10MB
--    أنواع الملفات: image/*
--
-- 2. تحقق من وجود الجداول:
--    SELECT table_name FROM information_schema.tables
--    WHERE table_schema = 'public'
--    AND table_name IN ('branch_transfers','transfer_items','branch_notifications');
--
-- 3. تحقق من الـ sequence:
--    SELECT next_transfer_number();
--    -- يجب أن يرجع: TRF-2026-06-000001
-- ════════════════════════════════════════════════════════════════
