-- ============================================
-- Слой Core: очистка, нормализация, SCD Type 2
-- ============================================

CREATE SCHEMA IF NOT EXISTS core;

-- --------------------------------------------
-- 1. Справочник дат (dim_date)
-- --------------------------------------------
CREATE TABLE core.dim_date (
    date_key        DATE PRIMARY KEY,
    year            INT,
    month           INT,
    day             INT,
    quarter         INT,
    weekday         INT,
    is_weekend      BOOLEAN
);

INSERT INTO core.dim_date
SELECT
    d::date,
    EXTRACT(YEAR FROM d),
    EXTRACT(MONTH FROM d),
    EXTRACT(DAY FROM d),
    EXTRACT(QUARTER FROM d),
    EXTRACT(ISODOW FROM d),
    EXTRACT(ISODOW FROM d) IN (6, 7)
FROM generate_series(DATE '2024-01-01', DATE '2024-12-31', INTERVAL '1 day') AS d;

COMMENT ON TABLE core.dim_date IS 'Календарь для витрин и отчётов';

-- --------------------------------------------
-- 2. Справочник магазинов (dim_store)
-- --------------------------------------------
CREATE TABLE core.dim_store (
    store_key       SERIAL PRIMARY KEY,
    store_id        TEXT UNIQUE NOT NULL,
    store_name      TEXT NOT NULL,
    city            TEXT
);

INSERT INTO core.dim_store (store_id, store_name, city)
SELECT DISTINCT
    TRIM(store_id),
    TRIM(store_name),
    TRIM(city)
FROM staging.stg_stores
WHERE store_id IS NOT NULL;

COMMENT ON TABLE core.dim_store IS 'Очищенный справочник магазинов';

-- --------------------------------------------
-- 3. Справочник товаров с SCD Type 2 (dim_product)
-- --------------------------------------------
CREATE TABLE core.dim_product (
    product_key     SERIAL PRIMARY KEY,
    product_id      TEXT NOT NULL,
    product_name    TEXT NOT NULL,
    category        TEXT,
    price           NUMERIC(10,2),
    valid_from      DATE NOT NULL,
    valid_to        DATE,
    is_current      BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (product_id, valid_from)
);

-- Загружаем первую версию каждого товара
INSERT INTO core.dim_product (product_id, product_name, category, price, valid_from, valid_to, is_current)
SELECT
    TRIM(product_id),
    TRIM(product_name),
    COALESCE(TRIM(category), 'Без категории'),
    NULLIF(TRIM(price), '')::NUMERIC(10,2),
    MIN(valid_from::DATE),
    NULL,
    TRUE
FROM staging.stg_products
WHERE product_id IS NOT NULL
GROUP BY TRIM(product_id), TRIM(product_name), COALESCE(TRIM(category), 'Без категории'), NULLIF(TRIM(price), '')::NUMERIC(10,2);

-- Закрываем старые версии и добавляем новые (упрощённый SCD2 для демонстрации)
WITH new_versions AS (
    SELECT
        TRIM(product_id) AS product_id,
        TRIM(product_name) AS product_name,
        COALESCE(TRIM(category), 'Без категории') AS category,
        NULLIF(TRIM(price), '')::NUMERIC(10,2) AS price,
        valid_from::DATE AS valid_from
    FROM staging.stg_products
    WHERE product_id IS NOT NULL
)
UPDATE core.dim_product dp
SET valid_to = nv.valid_from - INTERVAL '1 day',
    is_current = FALSE
FROM new_versions nv
WHERE dp.product_id = nv.product_id
  AND dp.is_current = TRUE
  AND (dp.price IS DISTINCT FROM nv.price OR dp.category IS DISTINCT FROM nv.category)
  AND nv.valid_from > dp.valid_from;

-- Вставляем новые версии (изменённые цена/категория)
INSERT INTO core.dim_product (product_id, product_name, category, price, valid_from, valid_to, is_current)
SELECT
    nv.product_id, nv.product_name, nv.category, nv.price, nv.valid_from, NULL, TRUE
FROM (
    SELECT
        TRIM(product_id) AS product_id,
        TRIM(product_name) AS product_name,
        COALESCE(TRIM(category), 'Без категории') AS category,
        NULLIF(TRIM(price), '')::NUMERIC(10,2) AS price,
        valid_from::DATE AS valid_from
    FROM staging.stg_products
    WHERE product_id IS NOT NULL
) nv
WHERE NOT EXISTS (
    SELECT 1 FROM core.dim_product dp
    WHERE dp.product_id = nv.product_id AND dp.valid_from = nv.valid_from
);

COMMENT ON TABLE core.dim_product IS 'SCD Type 2: история изменений товаров';
COMMENT ON COLUMN core.dim_product.valid_from IS 'Дата начала действия версии';
COMMENT ON COLUMN core.dim_product.valid_to IS 'Дата окончания действия версии (NULL = текущая)';
COMMENT ON COLUMN core.dim_product.is_current IS 'Флаг актуальной версии';

-- --------------------------------------------
-- 4. Факты продаж (fact_sales)
-- --------------------------------------------
CREATE TABLE core.fact_sales (
    sale_id         BIGINT PRIMARY KEY,
    date_key        DATE NOT NULL REFERENCES core.dim_date(date_key),
    store_key       INT NOT NULL REFERENCES core.dim_store(store_key),
    product_key     INT NOT NULL REFERENCES core.dim_product(product_key),
    quantity        INT,
    amount          NUMERIC(12,2),
    loaded_at       TIMESTAMP DEFAULT now()
);

-- Загружаем с очисткой: даты из трёх форматов, TRIM, приведение типов, дедупликация по sale_id
INSERT INTO core.fact_sales (sale_id, date_key, store_key, product_key, quantity, amount)
SELECT DISTINCT ON (s.sale_id)
    s.sale_id,
    CASE
        WHEN s.sale_date ~ '^\d{4}-\d{2}-\d{2}$' THEN s.sale_date::DATE
        WHEN s.sale_date ~ '^\d{2}\.\d{2}\.\d{4}$' THEN to_date(s.sale_date, 'DD.MM.YYYY')
        WHEN s.sale_date ~ '^\d{2}/\d{2}/\d{4}$' THEN to_date(s.sale_date, 'DD/MM/YYYY')
    END AS date_key,
    ds.store_key,
    dp.product_key,
    NULLIF(TRIM(s.quantity), '')::INT,
    NULLIF(TRIM(s.amount), '')::NUMERIC(12,2)
FROM staging.stg_sales s
JOIN core.dim_store ds ON ds.store_id = TRIM(s.store_id)
JOIN core.dim_product dp
  ON dp.product_id = TRIM(s.product_id)
 AND dp.is_current = TRUE
WHERE s.sale_id IS NOT NULL
  AND s.sale_date IS NOT NULL
ORDER BY s.sale_id;

COMMENT ON TABLE core.fact_sales IS 'Факты продаж, очищенные и связанные с измерениями';

-- Индексы для витрин
CREATE INDEX idx_fact_sales_date ON core.fact_sales (date_key);
CREATE INDEX idx_fact_sales_store ON core.fact_sales (store_key);
CREATE INDEX idx_fact_sales_product ON core.fact_sales (product_key);