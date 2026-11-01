-- ============================================
-- Наполнение Staging грязными данными
-- ============================================

-- 1. Магазины (10 штук, с лишними пробелами)
INSERT INTO staging.stg_stores (store_id, store_name, city)
SELECT
    (n)::text,
    ' Магазин ' || n || ' ',
    (ARRAY['Киров', 'Кирово-Чепецк', 'Слободской', 'Вятские Поляны'])[1 + (n % 4)]
FROM generate_series(1, 10) AS n;

-- 2. Товары (50 штук, с дублями и пропусками в категориях)
INSERT INTO staging.stg_products (product_id, product_name, category, price, valid_from)
SELECT
    (n)::text,
    'Товар ' || n,
    CASE WHEN n % 7 = 0 THEN NULL
         ELSE (ARRAY['Молочная продукция', 'Мясная продукция', 'Хлеб', 'Овощи', 'Напитки'])[1 + (n % 5)]
    END,
    (100 + n * 3)::text,
    '2024-01-01'
FROM generate_series(1, 50) AS n;

-- Дубли товаров (для проверки очистки на слое Core)
INSERT INTO staging.stg_products (product_id, product_name, category, price, valid_from)
SELECT
    (n)::text,
    ' Товар ' || n || ' ',   -- лишние пробелы
    (ARRAY['Молочная продукция', 'Мясная продукция'])[1 + (n % 2)],
    (100 + n * 3)::text,
    '2024-06-01'             -- новая версия (для SCD Type 2)
FROM generate_series(1, 10) AS n;

-- 3. Продажи (100 000 строк, с грязными форматами)
INSERT INTO staging.stg_sales (sale_id, sale_date, store_id, product_id, quantity, amount)
SELECT
    n,
    CASE
        WHEN n % 3 = 0 THEN to_char(DATE '2024-01-01' + (n % 365), 'DD.MM.YYYY')
        WHEN n % 3 = 1 THEN to_char(DATE '2024-01-01' + (n % 365), 'YYYY-MM-DD')
        ELSE to_char(DATE '2024-01-01' + (n % 365), 'DD/MM/YYYY')
    END,
    (1 + (n % 10))::text,
    (1 + (n % 50))::text,
    CASE WHEN n % 11 = 0 THEN NULL
         WHEN n % 5 = 0 THEN ' ' || (1 + (n % 5)) || ' '
         ELSE (1 + (n % 5))::text
    END,
    CASE WHEN n % 13 = 0 THEN NULL
         ELSE ((1 + (n % 5)) * (100 + (n % 50) * 3))::text
    END
FROM generate_series(1, 100000) AS n;