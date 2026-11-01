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

-- Загружаем все версии (без дублей по product_id + valid_from)
INSERT INTO core.dim_product (product_id, product_name, category, price, valid_from)
SELECT DISTINCT ON (TRIM(product_id), valid_from::DATE)
    TRIM(product_id),
    TRIM(product_name),
    COALESCE(TRIM(category), 'Без категории'),
    NULLIF(TRIM(price), '')::NUMERIC(10,2),
    valid_from::DATE
FROM staging.stg_products
WHERE product_id IS NOT NULL
ORDER BY TRIM(product_id), valid_from::DATE;

-- Закрываем все версии, кроме последней для каждого product_id
WITH ranked AS (
    SELECT product_key,
           ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY valid_from DESC) AS rn,
           LEAD(valid_from) OVER (PARTITION BY product_id ORDER BY valid_from) AS next_from
    FROM core.dim_product
)
UPDATE core.dim_product dp
SET is_current = (r.rn = 1),
    valid_to = CASE WHEN r.rn = 1 THEN NULL ELSE r.next_from - INTERVAL '1 day' END
FROM ranked r
WHERE dp.product_key = r.product_key;

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

-- --------------------------------------------
-- 5. Представление для выгрузки в ClickHouse
-- --------------------------------------------
CREATE OR REPLACE VIEW core.sales_denorm AS
SELECT
    fs.date_key,
    ds.store_name,
    ds.city,
    dp.product_name,
    dp.category,
    fs.quantity,
    fs.amount
FROM core.fact_sales fs
JOIN core.dim_store ds ON fs.store_key = ds.store_key
JOIN core.dim_product dp ON fs.product_key = dp.product_key;

-- Индексы для витрин
CREATE INDEX idx_fact_sales_date ON core.fact_sales (date_key);
CREATE INDEX idx_fact_sales_store ON core.fact_sales (store_key);
CREATE INDEX idx_fact_sales_product ON core.fact_sales (product_key);