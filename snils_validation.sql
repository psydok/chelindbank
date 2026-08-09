CREATE OR REPLACE PACKAGE snils_validation_pkg IS
    -- Перегруженные функции для проверки СНИЛС
    -- 1. Принимает строку с СНИЛС (с дефисами, пробелами или без)
    FUNCTION is_valid(p_snils IN VARCHAR2) RETURN BOOLEAN DETERMINISTIC;
    
    -- 2. Принимает первые 9 цифр и контрольное число отдельно
    FUNCTION is_valid(p_number IN VARCHAR2, p_control IN VARCHAR2) RETURN BOOLEAN DETERMINISTIC;
    
    -- 3. Принимает массив строк (для массовой проверки)
    TYPE snils_array IS TABLE OF VARCHAR2(20) INDEX BY PLS_INTEGER;
    FUNCTION is_valid(p_array IN snils_array) RETURN BOOLEAN DETERMINISTIC;
    
    -- Процедура массовой проверки СНИЛС в таблице с многопоточным режимом
    -- Параметры:
    --   p_table_name      - имя таблицы с данными
    --   p_column_name     - имя столбца, содержащего СНИЛС
    --   p_where_clause    - дополнительное условие WHERE (опционально)
    --   p_parallel_level  - степень параллелизма (количество потоков)
    PROCEDURE mass_validate(
        p_table_name     IN VARCHAR2,
        p_column_name    IN VARCHAR2,
        p_where_clause   IN VARCHAR2 DEFAULT NULL,
        p_parallel_level IN INTEGER DEFAULT 4
    );
    
    -- Процедура для записи результатов проверки в лог-таблицу
    PROCEDURE log_validation_result(
        p_snils      IN VARCHAR2,
        p_is_valid   IN BOOLEAN,
        p_error_msg  IN VARCHAR2 DEFAULT NULL
    );
END snils_validation_pkg;

CREATE OR REPLACE PACKAGE BODY snils_validation_pkg IS

    -- Вспомогательная функция очистки СНИЛС от нецифровых символов
    FUNCTION clean_snils(p_snils IN VARCHAR2) RETURN VARCHAR2 DETERMINISTIC IS
    BEGIN
        RETURN REGEXP_REPLACE(p_snils, '[^0-9]', '');
    END clean_snils;

    -- Основная логика проверки СНИЛС (внутренняя)
    FUNCTION validate_core(p_clean_snils IN VARCHAR2) RETURN BOOLEAN DETERMINISTIC IS
        v_sum      NUMBER := 0;
        v_remainder NUMBER;
        v_control  VARCHAR2(2);
        v_calc_control VARCHAR2(2);
    BEGIN
        -- Проверка длины
        IF LENGTH(p_clean_snils) != 11 THEN
            RETURN FALSE;
        END IF;
        
        -- Проверка, что номер > 001-001-998
        IF TO_NUMBER(SUBSTR(p_clean_snils, 1, 9)) <= 1001998 THEN
            RETURN FALSE;
        END IF;
        
        -- Вычисление суммы произведений
        FOR i IN 1..9 LOOP
            v_sum := v_sum + TO_NUMBER(SUBSTR(p_clean_snils, i, 1)) * (10 - i);
        END LOOP;
        
        -- Вычисление остатка от деления на 101
        v_remainder := MOD(v_sum, 101);
        
        -- Определение контрольного числа по остатку
        IF v_remainder = 100 OR v_remainder = 101 THEN
            v_calc_control := '00';
        ELSE
            v_calc_control := LPAD(TO_CHAR(v_remainder), 2, '0');
        END IF;
        
        -- Сравнение с указанным контрольным числом
        v_control := SUBSTR(p_clean_snils, 10, 2);
        RETURN v_control = v_calc_control;
    END validate_core;

    -- Перегруженная функция №1: принимает строку с СНИЛС
    FUNCTION is_valid(p_snils IN VARCHAR2) RETURN BOOLEAN DETERMINISTIC IS
        v_clean VARCHAR2(11);
    BEGIN
        v_clean := clean_snils(p_snils);
        RETURN validate_core(v_clean);
    END is_valid;

    -- Перегруженная функция №2: принимает номер и контрольное число отдельно
    FUNCTION is_valid(p_number IN VARCHAR2, p_control IN VARCHAR2) RETURN BOOLEAN DETERMINISTIC IS
        v_clean_number  VARCHAR2(9);
        v_clean_control VARCHAR2(2);
        v_full_snils    VARCHAR2(11);
    BEGIN
        v_clean_number := REGEXP_REPLACE(p_number, '[^0-9]', '');
        v_clean_control := REGEXP_REPLACE(p_control, '[^0-9]', '');
        
        IF LENGTH(v_clean_number) != 9 OR LENGTH(v_clean_control) != 2 THEN
            RETURN FALSE;
        END IF;
        
        v_full_snils := v_clean_number || v_clean_control;
        RETURN validate_core(v_full_snils);
    END is_valid;

    -- Перегруженная функция №3: принимает массив строк
    FUNCTION is_valid(p_array IN snils_array) RETURN BOOLEAN DETERMINISTIC IS
        v_idx PLS_INTEGER;
    BEGIN
        v_idx := p_array.FIRST;
        WHILE v_idx IS NOT NULL LOOP
            IF NOT is_valid(p_array(v_idx)) THEN
                RETURN FALSE;
            END IF;
            v_idx := p_array.NEXT(v_idx);
        END LOOP;
        RETURN TRUE;
    END is_valid;

    -- Процедура логирования
    PROCEDURE log_validation_result(
        p_snils     IN VARCHAR2,
        p_is_valid  IN BOOLEAN,
        p_error_msg IN VARCHAR2 DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO snils_validation_log (
            snils,
            is_valid,
            error_msg,
            check_date
        ) VALUES (
            p_snils,
            CASE WHEN p_is_valid THEN 'Y' ELSE 'N' END,
            p_error_msg,
            SYSDATE
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
    END log_validation_result;

    -- Процедура массовой проверки с многопоточным режимом
    PROCEDURE mass_validate(
        p_table_name     IN VARCHAR2,
        p_column_name    IN VARCHAR2,
        p_where_clause   IN VARCHAR2 DEFAULT NULL,
        p_parallel_level IN INTEGER DEFAULT 4
    ) IS
        v_sql     VARCHAR2(4000);
        v_chunk_sql VARCHAR2(4000);
        v_task_name VARCHAR2(30) := 'SNILS_VALIDATION_TASK';
    BEGIN
        -- Создаём задачу для DBMS_PARALLEL_EXECUTE
        DBMS_PARALLEL_EXECUTE.CREATE_TASK(v_task_name);
        
        -- Разбиваем таблицу на чанки по ROWID
        v_sql := 'SELECT ROWID FROM ' || p_table_name;
        IF p_where_clause IS NOT NULL THEN
            v_sql := v_sql || ' WHERE ' || p_where_clause;
        END IF;
        
        DBMS_PARALLEL_EXECUTE.CREATE_CHUNKS_BY_ROWID(
            task_name   => v_task_name,
            table_name  => p_table_name,
            by_row      => TRUE,
            chunk_size  => 1000
        );
        
        -- Формируем SQL для обработки каждого чанка
        v_chunk_sql := '
            DECLARE
                v_snils VARCHAR2(20);
                v_valid BOOLEAN;
            BEGIN
                FOR rec IN (
                    SELECT ' || p_column_name || ' AS snils
                    FROM ' || p_table_name || '
                    WHERE ROWID BETWEEN :start_id AND :end_id
                ) LOOP
                    v_valid := snils_validation_pkg.is_valid(rec.snils);
                    snils_validation_pkg.log_validation_result(
                        rec.snils,
                        v_valid,
                        CASE WHEN NOT v_valid THEN ''Некорректный СНИЛС'' ELSE NULL END
                    );
                END LOOP;
                COMMIT;
            END;';
        
        -- Запускаем параллельное выполнение
        DBMS_PARALLEL_EXECUTE.RUN_TASK(
            task_name      => v_task_name,
            sql_stmt       => v_chunk_sql,
            language_flag  => DBMS_SQL.NATIVE,
            parallel_level => p_parallel_level
        );
        
        -- Очищаем задачу
        DBMS_PARALLEL_EXECUTE.DROP_TASK(v_task_name);
    EXCEPTION
        WHEN OTHERS THEN
            -- В случае ошибки также удаляем задачу
            BEGIN
                DBMS_PARALLEL_EXECUTE.DROP_TASK(v_task_name);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            RAISE;
    END mass_validate;

END snils_validation_pkg;

CREATE TABLE snils_validation_log (
    id           NUMBER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    snils        VARCHAR2(20),
    is_valid     CHAR(1) CHECK (is_valid IN ('Y', 'N')),
    error_msg    VARCHAR2(4000),
    check_date   TIMESTAMP DEFAULT SYSTIMESTAMP
);

-- Индекс для быстрого поиска
CREATE INDEX idx_snils_log_snils ON snils_validation_log(snils);
CREATE INDEX idx_snils_log_date ON snils_validation_log(check_date);

-- Проверка одного СНИЛС
BEGIN
    IF snils_validation_pkg.is_valid('112-233-445 95') THEN
        DBMS_OUTPUT.PUT_LINE('СНИЛС корректен');
    ELSE
        DBMS_OUTPUT.PUT_LINE('СНИЛС некорректен');
    END IF;
END;


-- Проверка с разделением номера и контрольного числа
BEGIN
    IF snils_validation_pkg.is_valid('112233445', '95') THEN
        DBMS_OUTPUT.PUT_LINE('СНИЛС корректен');
    END IF;
END;


-- Массовая проверка всех СНИЛС в таблице employees (4 потока)
BEGIN
    snils_validation_pkg.mass_validate(
        p_table_name     => 'EMPLOYEES',
        p_column_name    => 'SNILS_NUMBER',
        p_where_clause   => 'status = ''ACTIVE''',
        p_parallel_level => 4
    );
END;
