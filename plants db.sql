/* ============================================================
   База данных PLANTS — управление пополнением растительных запасов
   Станция юных натуралистов, г. Канск
   СУБД: Microsoft SQL Server 2017 и выше
   ============================================================ */

IF DB_ID(N'PLANTS') IS NULL
    CREATE DATABASE PLANTS;
GO

USE PLANTS;
GO

/* ---------- 1. Таблицы ---------- */

CREATE TABLE plant_categories (
    category_id    INT IDENTITY(1,1) CONSTRAINT PK_plant_categories PRIMARY KEY,
    category_name  NVARCHAR(60) NOT NULL CONSTRAINT UQ_plant_categories UNIQUE
);
GO

CREATE TABLE suppliers (
    supplier_id    INT IDENTITY(1,1) CONSTRAINT PK_suppliers PRIMARY KEY,
    supplier_name  NVARCHAR(100) NOT NULL,
    phone          NVARCHAR(20)  NULL,
    email          NVARCHAR(100) NULL,
    lead_days      TINYINT NOT NULL CONSTRAINT DF_suppliers_lead DEFAULT 7
);
GO

CREATE TABLE plants (
    plant_id     INT IDENTITY(1,1) CONSTRAINT PK_plants PRIMARY KEY,
    plant_name   NVARCHAR(100) NOT NULL,
    category_id  INT NOT NULL
        CONSTRAINT FK_plants_categories REFERENCES plant_categories(category_id),
    unit         NVARCHAR(10) NOT NULL CONSTRAINT DF_plants_unit DEFAULT N'шт.',
    min_qty      INT NOT NULL CONSTRAINT DF_plants_min DEFAULT 0,
    max_qty      INT NOT NULL,
    supplier_id  INT NOT NULL
        CONSTRAINT FK_plants_suppliers REFERENCES suppliers(supplier_id),
    CONSTRAINT CK_plants_min CHECK (min_qty >= 0),
    CONSTRAINT CK_plants_minmax CHECK (max_qty >= min_qty)
);
GO

CREATE TABLE locations (
    location_id    INT IDENTITY(1,1) CONSTRAINT PK_locations PRIMARY KEY,
    location_name  NVARCHAR(60) NOT NULL CONSTRAINT UQ_locations UNIQUE
);
GO

CREATE TABLE orders (
    order_id       INT IDENTITY(1,1) CONSTRAINT PK_orders PRIMARY KEY,
    supplier_id    INT NOT NULL
        CONSTRAINT FK_orders_suppliers REFERENCES suppliers(supplier_id),
    order_date     DATE NOT NULL CONSTRAINT DF_orders_date DEFAULT (CAST(GETDATE() AS DATE)),
    status         NVARCHAR(20) NOT NULL CONSTRAINT DF_orders_status DEFAULT N'new',
    received_date  DATE NULL,
    CONSTRAINT CK_orders_status CHECK (status IN (N'new', N'sent', N'received', N'cancelled'))
);
GO

CREATE TABLE order_items (
    item_id   INT IDENTITY(1,1) CONSTRAINT PK_order_items PRIMARY KEY,
    order_id  INT NOT NULL
        CONSTRAINT FK_order_items_orders REFERENCES orders(order_id) ON DELETE CASCADE,
    plant_id  INT NOT NULL
        CONSTRAINT FK_order_items_plants REFERENCES plants(plant_id),
    quantity  INT NOT NULL CONSTRAINT CK_order_items_qty CHECK (quantity > 0),
    CONSTRAINT UQ_order_items UNIQUE (order_id, plant_id)
);
GO

CREATE TABLE stock_movements (
    movement_id    INT IDENTITY(1,1) CONSTRAINT PK_stock_movements PRIMARY KEY,
    plant_id       INT NOT NULL
        CONSTRAINT FK_movements_plants REFERENCES plants(plant_id),
    location_id    INT NOT NULL
        CONSTRAINT FK_movements_locations REFERENCES locations(location_id),
    movement_type  NVARCHAR(3) NOT NULL
        CONSTRAINT CK_movements_type CHECK (movement_type IN (N'IN', N'OUT')),
    quantity       INT NOT NULL CONSTRAINT CK_movements_qty CHECK (quantity > 0),
    movement_date  DATE NOT NULL CONSTRAINT DF_movements_date DEFAULT (CAST(GETDATE() AS DATE)),
    order_id       INT NULL
        CONSTRAINT FK_movements_orders REFERENCES orders(order_id),
    comment        NVARCHAR(200) NULL
);
GO

CREATE TABLE users (
    user_id        INT IDENTITY(1,1) CONSTRAINT PK_users PRIMARY KEY,
    login          NVARCHAR(50) NOT NULL CONSTRAINT UQ_users_login UNIQUE,
    password_hash  NVARCHAR(255) NOT NULL,
    role           NVARCHAR(20) NOT NULL
        CONSTRAINT CK_users_role CHECK (role IN (N'admin', N'teacher'))
);
GO

/* ---------- 2. Представления ---------- */

/* Текущие остатки и статус каждого растения */
CREATE VIEW v_stock AS
SELECT t.plant_id,
       t.plant_name,
       t.category_name,
       t.unit,
       t.min_qty,
       t.max_qty,
       t.supplier_id,
       t.qty,
       CASE WHEN t.qty = 0            THEN N'Критический'
            WHEN t.qty <= t.min_qty   THEN N'Требуется заказ'
            ELSE N'В норме' END AS status
FROM (
    SELECT p.plant_id, p.plant_name, c.category_name, p.unit,
           p.min_qty, p.max_qty, p.supplier_id,
           ISNULL(SUM(CASE m.movement_type WHEN N'IN'  THEN m.quantity
                                           WHEN N'OUT' THEN -m.quantity END), 0) AS qty
    FROM plants p
    JOIN plant_categories c ON c.category_id = p.category_id
    LEFT JOIN stock_movements m ON m.plant_id = p.plant_id
    GROUP BY p.plant_id, p.plant_name, c.category_name, p.unit,
             p.min_qty, p.max_qty, p.supplier_id
) t;
GO

/* Растения к заказу: остаток не выше минимума и нет незавершённой заявки.
   Рекомендуемое количество Q = Smax - Stek */
CREATE VIEW v_to_order AS
SELECT s.plant_id,
       s.plant_name,
       s.unit,
       s.supplier_id,
       s.qty,
       s.min_qty,
       s.max_qty,
       s.max_qty - s.qty AS recommended_qty
FROM v_stock s
WHERE s.qty <= s.min_qty
  AND NOT EXISTS (SELECT 1
                  FROM order_items oi
                  JOIN orders o ON o.order_id = oi.order_id
                  WHERE oi.plant_id = s.plant_id
                    AND o.status IN (N'new', N'sent'));
GO

/* Аналитика по поставщикам */
CREATE VIEW v_supplier_analytics AS
SELECT s.supplier_id,
       s.supplier_name,
       s.lead_days,
       COUNT(DISTINCT o.order_id)  AS orders_count,
       ISNULL(SUM(oi.quantity), 0) AS total_qty
FROM suppliers s
LEFT JOIN orders o       ON o.supplier_id = s.supplier_id AND o.status <> N'cancelled'
LEFT JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY s.supplier_id, s.supplier_name, s.lead_days;
GO

/* ---------- 3. Хранимые процедуры ---------- */

/* Формирование заявки поставщику на все растения с дефицитом */
CREATE PROCEDURE sp_CreateReplenishmentOrder
    @supplier_id INT,
    @order_id    INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM suppliers WHERE supplier_id = @supplier_id)
        THROW 50001, N'Поставщик с указанным кодом не найден', 1;

    IF NOT EXISTS (SELECT 1 FROM v_to_order WHERE supplier_id = @supplier_id)
        THROW 50002, N'Для этого поставщика нет растений к заказу', 1;

    BEGIN TRANSACTION;

    INSERT INTO orders (supplier_id) VALUES (@supplier_id);
    SET @order_id = SCOPE_IDENTITY();

    INSERT INTO order_items (order_id, plant_id, quantity)
    SELECT @order_id, plant_id, recommended_qty
    FROM v_to_order
    WHERE supplier_id = @supplier_id;

    COMMIT TRANSACTION;
END;
GO

/* Приёмка поставки: приход на склад и закрытие заявки */
CREATE PROCEDURE sp_ReceiveOrder
    @order_id    INT,
    @location_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM orders WHERE order_id = @order_id)
        THROW 50003, N'Заявка с указанным кодом не найдена', 1;

    IF NOT EXISTS (SELECT 1 FROM orders
                   WHERE order_id = @order_id AND status IN (N'new', N'sent'))
        THROW 50004, N'Заявка уже закрыта или отменена', 1;

    IF NOT EXISTS (SELECT 1 FROM locations WHERE location_id = @location_id)
        THROW 50005, N'Место хранения не найдено', 1;

    BEGIN TRANSACTION;

    INSERT INTO stock_movements (plant_id, location_id, movement_type, quantity, order_id, comment)
    SELECT plant_id, @location_id, N'IN', quantity, @order_id, N'Поставка по заявке'
    FROM order_items
    WHERE order_id = @order_id;

    UPDATE orders
    SET status = N'received',
        received_date = CAST(GETDATE() AS DATE)
    WHERE order_id = @order_id;

    COMMIT TRANSACTION;
END;
GO

/* Списание растений (раздача, посадка, падёж) */
CREATE PROCEDURE sp_WriteOff
    @plant_id    INT,
    @location_id INT,
    @quantity    INT,
    @comment     NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM plants WHERE plant_id = @plant_id)
        THROW 50006, N'Растение с указанным кодом не найдено', 1;

    INSERT INTO stock_movements (plant_id, location_id, movement_type, quantity, comment)
    VALUES (@plant_id, @location_id, N'OUT', @quantity, @comment);
END;
GO

/* ---------- 4. Триггер ---------- */
/* Запрет списания больше, чем есть в месте хранения */

CREATE TRIGGER trg_movements_no_negative
ON stock_movements
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1
        FROM (SELECT DISTINCT plant_id, location_id
              FROM inserted
              WHERE movement_type = N'OUT') i
        CROSS APPLY (SELECT SUM(CASE m.movement_type WHEN N'IN' THEN m.quantity
                                                     ELSE -m.quantity END) AS balance
                     FROM stock_movements m
                     WHERE m.plant_id = i.plant_id
                       AND m.location_id = i.location_id) b
        WHERE b.balance < 0
    )
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50010, N'Недостаточно растений в месте хранения для списания', 1;
    END
END;
GO

/* ---------- 5. Тестовые данные (условные) ---------- */

INSERT INTO plant_categories (category_name) VALUES
 (N'Комнатные растения'), (N'Рассада овощных культур'), (N'Рассада цветочных культур'),
 (N'Саженцы деревьев'), (N'Семена');

INSERT INTO suppliers (supplier_name, phone, email, lead_days) VALUES
 (N'Питомник «Зелёный сад»',   N'8-900-100-00-01', N'sad@example.ru',    5),
 (N'Агроцентр «Урожай»',        N'8-900-100-00-02', N'urozhay@example.ru', 3);

INSERT INTO locations (location_name) VALUES
 (N'Теплица'), (N'Учебный кабинет'), (N'Склад');

INSERT INTO plants (plant_name, category_id, unit, min_qty, max_qty, supplier_id) VALUES
 (N'Герань душистая',                    1, N'шт.',   5,  20, 1),
 (N'Фиалка узамбарская',                 1, N'шт.',   6,  24, 1),
 (N'Хлорофитум хохлатый',                1, N'шт.',   4,  16, 1),
 (N'Томат «Сибирский скороспелый» (рассада)', 2, N'шт.', 20, 100, 2),
 (N'Перец сладкий «Подарок Молдовы» (рассада)', 2, N'шт.', 15,  60, 2),
 (N'Огурец «Засолочный» (семена)',       5, N'пакет', 10,  50, 2),
 (N'Петуния гибридная (рассада)',        3, N'шт.',  30, 120, 1),
 (N'Бархатцы прямостоячие (семена)',     5, N'пакет', 10,  40, 2),
 (N'Туя западная «Смарагд» (саженец)',   4, N'шт.',  10,  40, 1),
 (N'Сосна обыкновенная (саженец)',       4, N'шт.',  10,  30, 1);

/* Исторические заявки */
INSERT INTO orders (supplier_id, order_date, status, received_date) VALUES
 (2, '2026-09-15', N'received', '2026-09-18'),
 (1, '2026-09-20', N'received', '2026-09-25');

INSERT INTO order_items (order_id, plant_id, quantity) VALUES
 (1, 4, 30), (1, 5, 20),
 (2, 7, 40), (2, 1, 10);

/* Начальные остатки и поступления по заявкам */
INSERT INTO stock_movements (plant_id, location_id, movement_type, quantity, movement_date, order_id, comment) VALUES
 (1, 1, N'IN', 10, '2026-09-01', NULL, N'Начальный остаток'),
 (2, 2, N'IN', 10, '2026-09-01', NULL, N'Начальный остаток'),
 (3, 2, N'IN', 12, '2026-09-01', NULL, N'Начальный остаток'),
 (4, 1, N'IN', 30, '2026-09-01', NULL, N'Начальный остаток'),
 (5, 1, N'IN', 30, '2026-09-01', NULL, N'Начальный остаток'),
 (6, 3, N'IN', 20, '2026-09-01', NULL, N'Начальный остаток'),
 (7, 1, N'IN', 60, '2026-09-01', NULL, N'Начальный остаток'),
 (8, 3, N'IN', 40, '2026-09-01', NULL, N'Начальный остаток'),
 (9, 3, N'IN', 15, '2026-09-01', NULL, N'Начальный остаток'),
 (10, 1, N'IN', 25, '2026-09-01', NULL, N'Начальный остаток'),
 (4, 1, N'IN', 30, '2026-09-18', 1, N'Поставка по заявке'),
 (5, 1, N'IN', 20, '2026-09-18', 1, N'Поставка по заявке'),
 (7, 1, N'IN', 40, '2026-09-25', 2, N'Поставка по заявке'),
 (1, 1, N'IN', 10, '2026-09-25', 2, N'Поставка по заявке');

/* Списания: раздача на занятия, посадка, продажа на ярмарке */
INSERT INTO stock_movements (plant_id, location_id, movement_type, quantity, movement_date, comment) VALUES
 (1, 1, N'OUT',  6, '2026-10-05', N'Раздача на занятиях'),
 (2, 2, N'OUT',  4, '2026-10-06', N'Раздача на занятиях'),
 (3, 2, N'OUT',  3, '2026-10-07', N'Раздача на занятиях'),
 (4, 1, N'OUT', 48, '2026-10-08', N'Высадка на пришкольный участок'),
 (5, 1, N'OUT', 10, '2026-10-08', N'Высадка на пришкольный участок'),
 (6, 3, N'OUT', 17, '2026-10-09', N'Выдача семян на занятия'),
 (7, 1, N'OUT', 25, '2026-10-12', N'Озеленение территории'),
 (8, 3, N'OUT', 15, '2026-10-13', N'Выдача семян на занятия'),
 (9, 3, N'OUT', 15, '2026-10-14', N'Акция «Аллея выпускников»'),
 (10, 1, N'OUT', 7, '2026-10-14', N'Акция «Аллея выпускников»');

/* Пароли хранятся только в виде хэша (для учебного примера — SHA-256) */
INSERT INTO users (login, password_hash, role) VALUES
 (N'admin',   CONVERT(NVARCHAR(255), HASHBYTES('SHA2_256', N'Admin#2026'), 2),   N'admin'),
 (N'teacher', CONVERT(NVARCHAR(255), HASHBYTES('SHA2_256', N'Teacher#2026'), 2), N'teacher');
GO

/* ---------- 6. Аналитические запросы ---------- */

/* Запрос 1. Растения, требующие заказа */
SELECT plant_name, qty, min_qty, max_qty, recommended_qty
FROM v_to_order
ORDER BY plant_name;

/* Запрос 2. Аналитика по поставщикам */
SELECT supplier_name, lead_days, orders_count, total_qty
FROM v_supplier_analytics
ORDER BY total_qty DESC;
GO
