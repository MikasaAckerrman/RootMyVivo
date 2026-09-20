package cn.nanoturtle.rootmys9280.manager.rootmy

import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Neo10RootFlow — kit-флоу ownroot для iQOO Neo 10 (I2405).
 *
 * Отличается от S24-флоу root-my-s24: вместо их cve-2026-43499-пейлоадов
 * и ksud late-load используется кит tadaki (cheese → KASLR slide →
 * slidepatch → insmod resukisu.ko → активация libksud.orig) и
 * САМОКОРОНА вместо установки отдельного менеджер-APK.
 *
 * Root-канал: файловый протокол cheese-демона (rootcmd/rootout) —
 * тот же RCMD-протокол, что в kit/oneclick.sh.
 */
object Neo10RootFlow {

    private const val T = "/data/local/tmp"
    private const val ROOTCMD = "$T/rootcmd"
    private const val ROOTOUT = "$T/rootout"

    /** Файлы кита в assets/kit → staging в /data/local/tmp.
     *  ownroot speed-fix: su_bin/oneclick.sh/ksu_loader.sh исключены из staging
     *  (su_bin == su по sha256, oneclick/ksu_loader — референс, не исполняются флоу):
     *  −2.2МБ передачи. */
    private val KIT_FILES = listOf(
        "cheese", "su", "slidepatch",
        "resukisu.ko.base.rsc", "resukisu.ko.base.canonical",
        "libksud.orig", "libksud.dm", "ksu_variant_flag",
        "device_reksu.sh", "getslide.sh", "nibblemath.sh",
    )

    /** Версия кита: маркер на устройстве; при совпадении staging ПРОПУСКАЕТСЯ
     *  (18.7→0МБ передачи на повторных прогонах — главный источник скорости). */
    private const val KIT_VERSION = "ownroot-kit-v1"
    private const val KIT_MARKER = "$T/.ownroot_kit"

    /** Запись лога: (строка) — вызов VM. */
    fun interface Logger { fun log(line: String) }

    private var rcmdCounter = 0

    /**
     * RCMD — файловый канал cheese root-демона.
     * Пишем shell-строку в rootcmd; демон исполняет её как root;
     * вывод читаем из rootout; ждём маркер RCMD_DONE_<n>.
     * Возвращает (rc-ish, вывод без маркера). Пустой вывод = таймаут.
     */
    private suspend fun rcmd(
        shellExecutor: ShellExecutor,
        cmd: String,
        timeoutSec: Int = 30,
    ): String {
        val marker = "RCMD_DONE_${++rcmdCounter}"
        // очистка предыдущего вывода отдельной командой: rootcmd-канал
        // чувствителен к порядку (демон пишет rootout по факту исполнения)
        shellExecutor.shell("rm -f $ROOTOUT 2>/dev/null")
        val payload = "{ $cmd; echo $marker; } > $ROOTOUT 2>&1"
        shellExecutor.writeFile(ROOTCMD, "666", payload.byteInputStream())
        val deadline = SystemClock.elapsedRealtime() + timeoutSec * 1000L
        val captureCmd = arrayOf("/system/bin/sh", "-c", "cat $ROOTOUT 2>/dev/null")
        while (SystemClock.elapsedRealtime() < deadline) {
            val out = runCatching { shellExecutor.capture(captureCmd) }.getOrDefault("")
            if (out.contains(marker)) {
                return out.substringBefore(marker).trim()
            }
            delay(400)
        }
        return ""
    }

    /** Живой root? Проба RCMD-канала (как have_root в oneclick.sh). */
    private suspend fun haveRoot(shellExecutor: ShellExecutor): Boolean {
        val out = rcmd(shellExecutor, "id", 8)
        return out.contains("uid=0")
    }

    /**
     * Staging кита на устройство. Возвращает null при ошибке (сообщение уже в лог).
     * ownroot speed-fix: после успешной выкладки пишет маркер $KIT_MARKER —
     * повторные прогоны пропускают 18.7МБ передачи (маркер + контроль присутствия
     * 4 ключевых файлов выше в run()).
     */
    private suspend fun stageKit(
        app: android.app.Application,
        shellExecutor: ShellExecutor,
        logger: Logger,
    ): Unit? = withContext(Dispatchers.IO) {
        logger.log("◆ Стилизация kit → /data/local/tmp (${KIT_FILES.size} файлов)")
        for (name in KIT_FILES) {
            val local = File(app.filesDir, "kit_$name")
            runCatching {
                app.assets.open("kit/$name").use { input ->
                    local.outputStream().use { input.copyTo(it) }
                }
            }.getOrElse {
                logger.log("✗ kit asset missing: $name")
                return@withContext null
            }
            // 755 для бинарей/скриптов, 644 для данных (.ko.base, флаг)
            val mode = if (name.startsWith("resukisu.ko") || name == "ksu_variant_flag") "644" else "755"
            try {
                shellExecutor.writeFile("$T/$name", mode, local.inputStream())
            } catch (t: Throwable) {
                logger.log("✗ stage fail: $name — ${t.message}")
                return@withContext null
            }
        }
        // маркер версии (через shell: файл пишется от shell — читаем и нам, и root)
        runCatching {
            shellExecutor.shell("echo $KIT_VERSION > $KIT_MARKER")
        }
        logger.log("✔ kit staged (${KIT_FILES.size} файлов, маркер $KIT_VERSION)")
    }

    /** kernelsu загружен? (ownroot fix: при ошибке чтения — false, не true) */
    private fun ksuLoaded(shellExecutor: ShellExecutor): Boolean = runCatching {
        val out = shellExecutor
            .capture(arrayOf("/system/bin/sh", "-c", "grep -c '^kernelsu ' /proc/modules 2>/dev/null"))
            .trim()
        out.isNotEmpty() && out != "0"
    }.getOrDefault(false)

    /**
     * Полный флоу. Возвращает Result<Unit>.
     * Лог пишет через logger; ошибки — в Result.failure(IllegalStateException(сообщение)).
     */
    suspend fun run(
        app: android.app.Application,
        shellExecutor: ShellExecutor,
        logger: Logger,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            logger.log("◆ ownroot Neo10 kit flow")

            // --- 1. Staging кита (ownroot speed-fix: скип по маркеру версии) ---
            val markerOnDevice = runCatching {
                shellExecutor.capture(
                    arrayOf("/system/bin/sh", "-c", "cat $KIT_MARKER 2>/dev/null")
                ).trim()
            }.getOrDefault("")
            if (markerOnDevice == KIT_VERSION) {
                // маркер есть, но файлы могли быть вычищены — дешёвая контрольная сумма
                // по количеству файлов (без md5: живая проверка присутствия)
                val present = runCatching {
                    shellExecutor.capture(
                        arrayOf("/system/bin/sh", "-c",
                            "ls $T/cheese $T/slidepatch $T/libksud.dm $T/resukisu.ko.base.rsc 2>/dev/null | wc -l")
                    ).trim()
                }.getOrDefault("0")
                if (present == "4") {
                    logger.log("✔ kit уже на устройстве ($KIT_VERSION) — staging пропущен")
                } else {
                    stageKit(app, shellExecutor, logger) ?:
                        return@withContext Result.failure(
                            IllegalStateException("staging кита не удался"))
                }
            } else {
                stageKit(app, shellExecutor, logger) ?:
                    return@withContext Result.failure(
                        IllegalStateException("staging кита не удался"))
            }

            // --- 2. cheese / root-канал (демон ОБЯЗАТЕЛЕН: все rcmd-стадии идут через него) ---
            // ownroot fix №2: haveRoot проверяется ПЕРВЫМ (не ksuLoaded) — rcmd-архитектуре
            // нужен живой демон; LKM-без-демона (краш демона) восстанавливается повторным
            // cheese (уязвимость в ядре остаётся, insmod позже идемпотентен).
            // pkill выполняется ТОЛЬКО в ветке пере-эксплойта — не убивает живой канал
            if (haveRoot(shellExecutor)) {
                logger.log("✔ root-канал уже жив — skip cheese")
            } else {
                shellExecutor.shell(
                    "pkill -9 cheese 2>/dev/null; rm -f $T/cheese.log $T/rootout; true"
                )
                logger.log("◆ cheese: privilege escalation (до 5 мин)")
                val env = arrayOf(
                    "CHEESE_CPURW=1", "CHEESE_NO_RETRY=1", "CHEESE_DROP_SU=1",
                    "CHEESE_ROOT_DAEMON=1", "CHEESE_CPURW_VERBOSE=1", "CHEESE_PATCH_VR=1",
                    "CHEESE_PHYSCAN_BASE=0xa3000000",
                    "CHEESE_PHYSCAN_END=0xae000000",
                    "CHEESE_PHYSCAN_STRIDE=0x1000000",
                )
                val startedAt = SystemClock.elapsedRealtime()
                // cheese фоновится сам (ROOT_DAEMON), процесс-обёртка завершается
                shellExecutor.exec(
                    arrayOf("/system/bin/sh", "-c",
                        "cd $T && ./cheese > $T/cheese.log 2>&1"),
                    env,
                )
                var rooted = false
                while (SystemClock.elapsedRealtime() - startedAt < 300_000L) {
                    if (haveRoot(shellExecutor)) { rooted = true; break }
                    delay(2000)
                    if (((SystemClock.elapsedRealtime() - startedAt) / 1000L) % 30L == 0L) {
                        val tail = shellExecutor.capture(
                            arrayOf("/system/bin/sh", "-c", "tail -c 200 $T/cheese.log 2>/dev/null")
                        ).trim()
                        if (tail.isNotEmpty()) logger.log("… $tail")
                    }
                }
                if (!rooted) {
                    return@withContext Result.failure(IllegalStateException(
                        "cheese не дал root за 5 мин. Перезагрузи телефон и запусти снова " +
                        "(окно ≤75с после бута даёт лучшие шансы)."))
                }
                // ownroot fix: даём cheese.log дописать leak-строки (slide нужен дальше),
                // демон форкается раньше, чем лог флешнится
                delay(2500)
                logger.log("✔ root-демон жив")
            }

            // --- 3. Миграция в /data/local/tmp2 ---
            // ownroot fix №1 (ФАТАЛЬНЫЙ): device_reksu.sh делает `cd /data/local/tmp2`
            // и ждёт там slidepatch/.ko — oneclick мигрирует их стадией 2.5; без этого
            // slidepatch получает PATCH_FAIL. Миграция ЧЕРЕЗ rcmd — поэтому стоит ПОСЛЕ
            // получения root (в ранней версии стояла до cheese → на свежем буте 30с
            // таймаута и пустая tmp2)
            val mig = rcmd(shellExecutor,
                "/system/bin/mkdir -p /data/local/tmp2; " +
                "for f in slidepatch device_reksu.sh getslide.sh libksud.orig libksud.dm " +
                "resukisu.ko.base.canonical resukisu.ko.base.rsc ksu_variant_flag; do " +
                "/system/bin/cp /data/local/tmp/$f /data/local/tmp2/$f; done; " +
                "/system/bin/chmod 755 /data/local/tmp2/slidepatch " +
                "/data/local/tmp2/device_reksu.sh /data/local/tmp2/getslide.sh " +
                "/data/local/tmp2/libksud.orig /data/local/tmp2/libksud.dm; " +
                "/system/bin/ls /data/local/tmp2 | /system/bin/wc -l", 30)
            if (mig.isBlank() || mig.trim() == "0") {
                return@withContext Result.failure(IllegalStateException(
                    "миграция в /data/local/tmp2 не удалась (root-канал жив?)"))
            }
            logger.log("✔ tmp2: ${mig.trim().take(60)} файлов")

            // --- 4. slide + insmod ---
            if (ksuLoaded(shellExecutor)) {
                logger.log("✔ kernelsu уже загружен — skip insmod")
            } else {
                logger.log("◆ KASLR slide + insmod")
                val gs = shellExecutor.shell("sh $T/getslide.sh 2>&1")
                val slide = Regex("SLIDE=0x([0-9a-fA-F]+)")
                    .find(gs.second)?.groupValues?.get(1)
                if (slide.isNullOrEmpty()) {
                    return@withContext Result.failure(IllegalStateException(
                        "slide не найден в cheese.log: ${gs.second.trim().takeLast(200)}"))
                }
                logger.log("✔ SLIDE=0x$slide")
                val load = rcmd(shellExecutor, "sh $T/device_reksu.sh $slide", 60)
                if (!load.contains("MODULE_LOADED") && !ksuLoaded(shellExecutor)) {
                    return@withContext Result.failure(IllegalStateException(
                        "insmod fail: ${load.trim().takeLast(300)}"))
                }
                logger.log("✔ kernelsu LKM загружен")
            }

            // --- 5. Активация (оригинальный libksud: post-fs-data + boot-completed) ---
            // ownroot fix: все команды с АБСОЛЮТНЫМИ путями — у rootcmd-демона нет PATH,
            // execvp("chmod") падает с ENOENT (проверено на живом устройстве)
            logger.log("◆ Активация модулей (libksud.orig)")
            val act = rcmd(shellExecutor,
                "$T/su -c '/system/bin/chmod 755 $T/libksud.orig; " +
                "$T/libksud.orig post-fs-data; " +
                "$T/libksud.orig boot-completed' 2>&1", 90)
            logger.log("активация: ${act.trim().takeLast(300)}")

            // --- 6. САМОКОРОНА: это приложение становится менеджером ---
            logger.log("◆ Самокорона менеджера")
            val ownApk = app.packageCodePath
            val crown = rcmd(shellExecutor,
                "$T/su -c '$T/libksud.dm kernel dynamic-manager set-apk $ownApk' 2>&1", 45)
            // ownroot fix: корона ОБЯЗАТЕЛЬНО верифицируется по dmesg (Crowning manager),
            // греппим ИМЕННО наш пакет — в dmesg могут оставаться строки коронаций других менеджеров
            val crownProof = rcmd(shellExecutor,
                "/system/bin/dmesg | /system/bin/grep -a 'Crowning manager: ${app.packageName}' | /system/bin/tail -1", 15)
            if (crownProof.isBlank() || !crownProof.contains("Crowning")) {
                val dm = shellExecutor.capture(
                    arrayOf("/system/bin/sh", "-c", "cat /data/adb/ksu/.dynamic_manager 2>/dev/null")
                ).trim()
                return@withContext Result.failure(IllegalStateException(
                    "Самокорона не подтверждена (dmesg без 'Crowning manager'). " +
                    "set-apk: ${crown.trim().takeLast(150)}; dynamic_manager: ${dm.takeLast(80)}"))
            }
            logger.log("✔ корона: ${crownProof.trim().take(120)}")

            // --- 7. Верификация ---
            val mods = shellExecutor.capture(
                arrayOf("/system/bin/sh", "-c", "grep kernelsu /proc/modules 2>/dev/null")
            ).trim()
            if (mods.isEmpty()) {
                logger.log("⚠ kernelsu не виден в /proc/modules (проверь после soft-reboot)")
            } else {
                logger.log("✔ /proc/modules: ${mods.take(80)}")
            }
            logger.log("🎉 ROOT готов — менеджер ЭТО приложение. Один APK.")
            Result.success(Unit)
        } catch (t: Throwable) {
            Result.failure(t)
        }
    }
}
