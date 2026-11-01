<h1>Учебный DWH: от грязных данных до аналитической витрины</h1>

<p>Pet-проект, демонстрирующий полный цикл построения корпоративного хранилища данных (DWH) на примере агрохолдинга с розничной сетью: от сырых данных из кассовой системы до аналитической витрины в ClickHouse.</p>

<h2>Архитектура</h2>

<pre><code>Staging (PostgreSQL) → Core (PostgreSQL) → Mart (ClickHouse)
   грязные данные      очистка, SCD2,        денормализация,
                       звёздная схема       партиционирование</code></pre>

<ul>
  <li><b>Staging</b> — сырые данные «как пришли»: даты в трёх форматах, пробелы, NULL, дубли.</li>
  <li><b>Core</b> — очищенные данные: приведение типов, дедупликация, справочники (dim_*), таблица фактов (fact_sales), SCD Type 2 для истории изменений товаров.</li>
  <li><b>Mart</b> — денормализованная витрина в ClickHouse (MergeTree, PARTITION BY toYYYYMM, ORDER BY), оптимизированная под аналитические запросы.</li>
</ul>

<h2>Модель данных (Core)</h2>

<table>
  <thead>
    <tr>
      <th>Таблица</th>
      <th>Тип</th>
      <th>Описание</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>core.dim_date</code></td>
      <td>измерение</td>
      <td>Календарь 2024 года (366 дней)</td>
    </tr>
    <tr>
      <td><code>core.dim_store</code></td>
      <td>измерение</td>
      <td>10 магазинов, очищенные названия и города</td>
    </tr>
    <tr>
      <td><code>core.dim_product</code></td>
      <td>измерение (SCD2)</td>
      <td>50 товаров + 10 исторических версий, valid_from/valid_to/is_current</td>
    </tr>
    <tr>
      <td><code>core.fact_sales</code></td>
      <td>факт</td>
      <td>100 000 продаж, внешние ключи на измерения</td>
    </tr>
    <tr>
      <td><code>core.sales_denorm</code></td>
      <td>view</td>
      <td>Денормализованное представление для загрузки в Mart</td>
    </tr>
  </tbody>
</table>

<h2>Контроль качества данных</h2>

<p>В проекте реализованы и проверены:</p>

<ul>
  <li><b>Целостность</b>: 0 «сирот» в fact_sales (все ключи находятся в измерениях).</li>
  <li><b>Очистка дат</b>: три формата (YYYY-MM-DD, DD.MM.YYYY, DD/MM/YYYY) приведены к DATE, 0 некорректных дат.</li>
  <li><b>SCD Type 2</b>: у каждого товара ровно одна текущая версия (is_current = true).</li>
  <li><b>Согласованность Core ↔ Mart</b>: сумма продаж совпадает до копейки (44 182 568.00).</li>
  <li><b>Осознанная фильтрация</b>: из 100 000 фактов в витрину попало 83 917 — отфильтрованы 16 083 строки с NULL в количестве или сумме.</li>
</ul>

<h2>Обнаруженные и исправленные проблемы</h2>

<ol>
  <li><b>Потеря строк при JOIN в ClickHouse.</b> При загрузке Mart через три отдельных postgresql()-источника ClickHouse терял часть строк. Решение: вынести JOIN в PostgreSQL View (core.sales_denorm) и читать в ClickHouse одну готовую таблицу.</li>
  <li><b>Две текущие версии в SCD2.</b> У двух товаров дубли не меняли цену, и UPDATE не закрывал старую версию. Решение: пересобрать dim_product с ROW_NUMBER() по valid_from DESC.</li>
</ol>

<h2>Запуск</h2>
<p>1. Поднять контейнеры:</p>
<pre><code>docker compose up -d</code></pre>
<p>2. Выполнить SQL-скрипты по порядку:</p>
<pre><code>docker exec -i dwh-postgres psql -U postgres -d dwh -f /sql/01_staging.sql
docker exec -i dwh-postgres psql -U postgres -d dwh -f /sql/02_staging_data.sql
docker exec -i dwh-postgres psql -U postgres -d dwh -f /sql/03_core.sql
docker exec -i dwh-clickhouse clickhouse-client --multiquery --queries-file /sql/04_mart_clickhouse.sql</code></pre>

<h2>Подключение через DBeaver</h2>
<ul>
  <li><b>PostgreSQL</b>: localhost:5432, БД dwh, пользователь postgres, пароль postgres.</li>
  <li><b>ClickHouse</b>: localhost:8123, БД mart, пользователь admin, пароль admin123. Если возникает ошибка Invalid LZ4 magic byte, в настройках драйвера установите compress=false.</li>
</ul>

<h2>Навыки, продемонстрированные в проекте</h2>
<ul>
  <li>Проектирование слоёв DWH (Staging / Core / Mart).</li>
  <li>Нормализация, очистка и контроль качества данных.</li>
  <li>Размерное моделирование: звёздная схема, измерения, факты.</li>
  <li>SCD Type 2 (история изменений).</li>
  <li>PostgreSQL: оконные функции, FILTER, DISTINCT ON, View.</li>
  <li>ClickHouse: MergeTree, партиционирование, ключ сортировки.</li>
  <li>Docker / Docker Compose: изоляция сервисов, volumes, сети.</li>
</ul>