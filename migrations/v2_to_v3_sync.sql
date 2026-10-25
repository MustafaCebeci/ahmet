-- ============================================================
-- Migration: v2_to_v3_sync
-- Purpose : Eski sema (v2_db.sql) ile v3_db.sql arasindaki farklari
--           kontrol ederek tamamlar. Var olan kolon/tablo/FK'e
--           dokunmaz, sadece eksik olani ekler. Tekrar calistirilabilir.
-- Kullanim: Hedef veritabanini sec, sonra bu dosyayi calistir:
--             USE `<sema_adi>`;  -- ya da: mysql <sema_adi> < v2_to_v3_sync.sql
--           Sema adi DATABASE() uzerinden alinir, sabit yazilmaz.
-- Not     : DATETIME -> VARCHAR donusumu veri tipini degistirdigi icin
--           varsayilan KAPALI. Acmak icin asagidaki @convert_datetime = 1 yap.
-- ============================================================

SET @db := DATABASE();
SET @convert_datetime := 0;   -- 1 yapilirsa appointments/sms_messages tarih kolonlari VARCHAR olur

-- ------------------------------------------------------------
-- Yardimci: kolon yoksa ekle
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS _mig_add_column;
DROP PROCEDURE IF EXISTS _mig_add_fk;
DROP PROCEDURE IF EXISTS _mig_modify_if_shorter;
DROP PROCEDURE IF EXISTS _mig_datetime_to_varchar;

DELIMITER $$

CREATE PROCEDURE _mig_add_column(IN p_table VARCHAR(64), IN p_column VARCHAR(64), IN p_ddl TEXT)
BEGIN
  IF EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES
             WHERE TABLE_SCHEMA = @db AND TABLE_NAME = p_table)
     AND NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
                     WHERE TABLE_SCHEMA = @db AND TABLE_NAME = p_table AND COLUMN_NAME = p_column) THEN
    SET @s := CONCAT('ALTER TABLE `', p_table, '` ADD COLUMN ', p_ddl);
    PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
  END IF;
END$$

-- FK yoksa ekle (isim bazli)
CREATE PROCEDURE _mig_add_fk(IN p_table VARCHAR(64), IN p_fk VARCHAR(64), IN p_ddl TEXT)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
                 WHERE CONSTRAINT_SCHEMA = @db AND TABLE_NAME = p_table
                   AND CONSTRAINT_NAME = p_fk AND CONSTRAINT_TYPE = 'FOREIGN KEY') THEN
    SET @s := CONCAT('ALTER TABLE `', p_table, '` ADD CONSTRAINT `', p_fk, '` ', p_ddl);
    PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
  END IF;
END$$

-- VARCHAR kolon mevcut uzunluktan kisaysa genislet
CREATE PROCEDURE _mig_modify_if_shorter(IN p_table VARCHAR(64), IN p_column VARCHAR(64),
                                        IN p_len INT, IN p_ddl TEXT)
BEGIN
  DECLARE cur_len BIGINT DEFAULT NULL;
  SELECT CHARACTER_MAXIMUM_LENGTH INTO cur_len FROM INFORMATION_SCHEMA.COLUMNS
   WHERE TABLE_SCHEMA = @db AND TABLE_NAME = p_table AND COLUMN_NAME = p_column
     AND DATA_TYPE = 'varchar';
  IF cur_len IS NOT NULL AND cur_len < p_len THEN
    SET @s := CONCAT('ALTER TABLE `', p_table, '` MODIFY COLUMN `', p_column, '` ', p_ddl);
    PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
  END IF;
END$$

-- DATETIME kolonu varsa VARCHAR'a cevir (sadece @convert_datetime = 1)
CREATE PROCEDURE _mig_datetime_to_varchar(IN p_table VARCHAR(64), IN p_column VARCHAR(64),
                                          IN p_len INT, IN p_null_sql VARCHAR(40))
BEGIN
  IF @convert_datetime = 1 AND EXISTS (
       SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = @db AND TABLE_NAME = p_table AND COLUMN_NAME = p_column
          AND DATA_TYPE IN ('datetime', 'timestamp')) THEN
    SET @s := CONCAT('ALTER TABLE `', p_table, '` MODIFY COLUMN `', p_column,
                     '` VARCHAR(', p_len, ') ', p_null_sql);
    PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
  END IF;
END$$

DELIMITER ;

-- ------------------------------------------------------------
-- 1) appointments.source
-- ------------------------------------------------------------
CALL _mig_add_column('appointments', 'source',
  "`source` ENUM('customer','barber','system') NOT NULL DEFAULT 'barber'");

-- ------------------------------------------------------------
-- 2) customers.nickname (yoksa ekle, kisaysa 120'ye genislet)
-- ------------------------------------------------------------
CALL _mig_add_column('customers', 'nickname', "`nickname` VARCHAR(120) NULL DEFAULT NULL");
CALL _mig_modify_if_shorter('customers', 'nickname', 120, 'VARCHAR(120) NULL DEFAULT NULL');

-- ------------------------------------------------------------
-- 3) sounds tablosu + services.sound_id (+ FK)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `sounds` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `name` VARCHAR(200) NOT NULL,
  `path` VARCHAR(500) NOT NULL,
  `created_at` VARCHAR(60) NULL,
  `updated_at` VARCHAR(60) NULL,
  PRIMARY KEY (`id`))
ENGINE = InnoDB DEFAULT CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

CALL _mig_add_column('services', 'sound_id', "`sound_id` BIGINT UNSIGNED NULL DEFAULT NULL");
CALL _mig_add_fk('services', 'fk_services_sound',
  'FOREIGN KEY (`sound_id`) REFERENCES `sounds` (`id`) ON DELETE SET NULL');

-- ------------------------------------------------------------
-- 4) services.is_default (v3_db.sql'de eksik, seed bunu kullaniyor)
-- ------------------------------------------------------------
CALL _mig_add_column('services', 'is_default',
  "`is_default` TINYINT(1) NOT NULL DEFAULT 0 AFTER `is_active`");

UPDATE `services`
   SET `is_default` = 1
 WHERE `id` = (SELECT id FROM (SELECT MIN(id) AS id FROM `services`) AS t)
   AND NOT EXISTS (SELECT 1 FROM (SELECT 1 FROM `services` WHERE `is_default` = 1) AS d);

-- ------------------------------------------------------------
-- 5) reserved_slots
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `reserved_slots` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `provider_id` BIGINT UNSIGNED NOT NULL,
  `customer_id` BIGINT UNSIGNED NULL DEFAULT NULL COMMENT 'Opsiyonel - kimin icin rezerve',
  `day_of_week` VARCHAR(10) NOT NULL COMMENT 'Monday, Tuesday, ..., Sunday',
  `start_time` VARCHAR(80) NOT NULL,
  `end_time` VARCHAR(80) NOT NULL,
  `recurrence_weeks` TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT 'Her N haftada bir',
  `beginning` VARCHAR(80) NULL DEFAULT NULL COMMENT 'Yinelenmenin baslayacagi tarih (YYYY-MM-DD) - NULL = sonsuz',
  `is_active` TINYINT(1) NOT NULL DEFAULT 1,
  `note` VARCHAR(500) NULL DEFAULT NULL,
  `created_at` VARCHAR(60) NULL,
  `updated_at` VARCHAR(60) NULL,
  PRIMARY KEY (`id`),
  INDEX `idx_reserved_provider_active` (`provider_id` ASC, `is_active` ASC),
  INDEX `idx_reserved_day_provider` (`day_of_week` ASC, `provider_id` ASC),
  INDEX `idx_reserved_beginning` (`beginning` ASC),
  CONSTRAINT `fk_reserved_provider`
    FOREIGN KEY (`provider_id`) REFERENCES `service_providers` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_reserved_customer`
    FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE RESTRICT
) ENGINE = InnoDB DEFAULT CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ------------------------------------------------------------
-- 6) incoming_whatsapp_messages
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `incoming_whatsapp_messages` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `message_id` VARCHAR(120) NOT NULL COMMENT 'WhatsApp message ID (idempotency key)',
  `phone` VARCHAR(20) NOT NULL,
  `from_name` VARCHAR(200) NULL DEFAULT NULL,
  `app_id` VARCHAR(60) NULL DEFAULT NULL,
  `payload` JSON NOT NULL COMMENT 'Full webhook payload for debugging',
  `processed` TINYINT(1) NOT NULL DEFAULT 0 COMMENT '0=islenmedi, 1=islendi',
  `processed_at` VARCHAR(60) NULL DEFAULT NULL,
  `created_at` VARCHAR(60) NULL DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE INDEX `uq_incoming_wa_msg_id` (`message_id` ASC),
  INDEX `idx_incoming_wa_phone` (`phone` ASC),
  INDEX `idx_incoming_wa_processed` (`processed` ASC)
) ENGINE = InnoDB DEFAULT CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ------------------------------------------------------------
-- 7) whatsapp_messages
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `whatsapp_messages` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `appointment_id` BIGINT UNSIGNED NULL DEFAULT NULL,
  `customer_id` BIGINT UNSIGNED NULL DEFAULT NULL,
  `to_phone` VARCHAR(20) NOT NULL,
  `type` ENUM('reminder','otp','cancellation','other') NOT NULL DEFAULT 'other',
  `source` ENUM('cron','manual','api','system') NOT NULL DEFAULT 'system',
  `body` VARCHAR(800) NOT NULL,
  `wa_message_id` VARCHAR(120) NULL DEFAULT NULL COMMENT 'WhatsApp Cloud API message ID',
  `template_name` VARCHAR(100) NULL DEFAULT NULL,
  `status` ENUM('queued','sent','delivered','read','failed','cancelled') NOT NULL DEFAULT 'queued',
  `error_message` VARCHAR(300) NULL DEFAULT NULL,
  `scheduled_at` VARCHAR(60) NOT NULL,
  `sent_at` VARCHAR(60) NULL DEFAULT NULL,
  `created_at` VARCHAR(60) NULL DEFAULT NULL,
  `updated_at` VARCHAR(60) NULL DEFAULT NULL,
  PRIMARY KEY (`id`),
  INDEX `idx_wa_queue` (`status`, `scheduled_at`),
  INDEX `idx_wa_appointment` (`appointment_id`),
  INDEX `idx_wa_customer` (`customer_id`),
  INDEX `idx_wa_phone` (`to_phone`),
  INDEX `idx_wa_wa_id` (`wa_message_id`),
  CONSTRAINT `fk_wa_msg_appt`
    FOREIGN KEY (`appointment_id`) REFERENCES `appointments` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_wa_msg_customer`
    FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE SET NULL
) ENGINE = InnoDB DEFAULT CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- ------------------------------------------------------------
-- 8) (Opsiyonel) DATETIME -> VARCHAR tarih kolonlari  [@convert_datetime = 1]
--    Mevcut degerler 'YYYY-MM-DD HH:MM:SS.mmm' metnine donusur.
-- ------------------------------------------------------------
CALL _mig_datetime_to_varchar('appointments', 'start_at',   80, 'NOT NULL');
CALL _mig_datetime_to_varchar('appointments', 'end_at',     80, 'NOT NULL');
CALL _mig_datetime_to_varchar('appointments', 'created_at', 60, 'NULL DEFAULT NULL');
CALL _mig_datetime_to_varchar('appointments', 'updated_at', 60, 'NULL DEFAULT NULL');
CALL _mig_datetime_to_varchar('sms_messages', 'scheduled_at', 60, 'NOT NULL');
CALL _mig_datetime_to_varchar('sms_messages', 'sent_at',      60, 'NULL DEFAULT NULL');
CALL _mig_datetime_to_varchar('sms_messages', 'created_at',   60, 'NULL DEFAULT NULL');
CALL _mig_datetime_to_varchar('sms_messages', 'updated_at',   60, 'NULL DEFAULT NULL');

-- ------------------------------------------------------------
-- Temizlik
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS _mig_add_column;
DROP PROCEDURE IF EXISTS _mig_add_fk;
DROP PROCEDURE IF EXISTS _mig_modify_if_shorter;
DROP PROCEDURE IF EXISTS _mig_datetime_to_varchar;
