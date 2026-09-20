package cn.nanoturtle.rootmys9280.manager.ui.screens.modules

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray

/**
 * ModulesViewModel — менеджер модулей ownroot (v1: CLI через встроенный libksud.dm).
 *
 * Root-канал: /data/local/tmp/su (kernel-hooked su, allow_shell=1 — дропается cheese
 * и НЕ удаляется нашим флоу). После полного ребута (до повторного прогона рута)
 * su не отвечает — экран честно показывает «нет root».
 */
class ModulesViewModel(app: Application) : AndroidViewModel(app) {

    data class ModuleEntry(
        val id: String,
        val name: String,
        val version: String,
        val enabled: Boolean,
    )

    data class UiState(
        val loading: Boolean = false,
        val hasRoot: Boolean = true,
        val modules: List<ModuleEntry> = emptyList(),
        val message: String = "",
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state

    private val su = "/data/local/tmp/su"
    // ownroot fix: имя файла = как в assets/staging (libksud.dm, с точкой);
    // раньше тут был libksud_dm (подчёркивание) — exec несуществующего пути
    private val ksud = "/data/local/tmp/libksud.dm"

    /** Выполнить команду от root. null = root-канал недоступен. */
    private suspend fun rootExec(cmd: String, timeoutMs: Long = 20_000L): String? =
        withContext(Dispatchers.IO) {
            val full = "$su $cmd 2>&1"
            // su <cmd>: без -c (клиент cheese не поддерживает -c)
            val proc = ProcessBuilder("/system/bin/sh", "-c", full).start()
            val out = StringBuilder()
            val t1 = Thread { proc.inputStream.bufferedReader().use { out.append(it.readText()) } }
            val t2 = Thread { proc.errorStream.bufferedReader().use { out.append(it.readText()) } }
            t1.isDaemon = true; t2.isDaemon = true
            t1.start(); t2.start()
            val done = runCatching { proc.waitFor(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS) }
                .getOrDefault(false)
            if (!done) { proc.destroyForcibly(); return@withContext null }
            t1.join(2000); t2.join(2000)
            val text = out.toString().trim()
            if (text.contains("not found") && text.contains("su")) null else text
        }

    fun refresh() {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, message = "")
            // проверка root-канала ДО листинга: иначе «su не работает» выглядит как «модулей нет»
            val id = rootExec("id", 10_000L)
            if (id == null || !id.contains("uid=0")) {
                _state.value = _state.value.copy(loading = false, hasRoot = false,
                    message = "Root-канал недоступен. Запусти «Получить ROOT» и повтори.")
                return@launch
            }
            val out = rootExec("$ksud module list") ?: ""
            val modules = parseModules(out)
            _state.value = _state.value.copy(
                loading = false, hasRoot = true, modules = modules,
                message = if (modules.isEmpty()) "Модулей нет" else "",
            )
        }
    }

    private fun parseModules(raw: String): List<ModuleEntry> {
        val start = raw.indexOf('[')
        if (start < 0) return emptyList()
        return runCatching {
            val arr = JSONArray(raw.substring(start))
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.getJSONObject(i)
                ModuleEntry(
                    id = o.optString("id", "?"),
                    name = o.optString("name", o.optString("id", "?")),
                    version = o.optString("version", "?"),
                    enabled = o.optBoolean("enabled", false),
                )
            }
        }.getOrDefault(emptyList())
    }

    fun install(zip: Uri, cacheCopy: java.io.File) {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, message = "Установка…")
            val ok = withContext(Dispatchers.IO) {
                runCatching {
                    getApplication<Application>().contentResolver.openInputStream(zip)?.use { input ->
                        cacheCopy.outputStream().use { input.copyTo(it) }
                    } ?: return@withContext false
                    true
                }.getOrDefault(false)
            }
            if (!ok) {
                _state.value = _state.value.copy(loading = false, message = "Не удалось прочитать ZIP")
                return@launch
            }
            val out = rootExec("$ksud module install '${cacheCopy.absolutePath}'", 60_000L)
            val success = out != null && (out.contains("done") || out.contains("install") &&
                    !out.contains("error", ignoreCase = true))
            _state.value = _state.value.copy(loading = false,
                message = if (success) "Установлено. Перезапусти флоу для активации."
                          else "Ошибка: ${(out ?: "нет root").takeLast(200)}")
            refresh()
        }
    }

    fun uninstall(id: String) {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, message = "Удаление $id…")
            val out = rootExec("$ksud module uninstall '$id'")
            _state.value = _state.value.copy(loading = false,
                message = if (out != null) "Удалено (окончательно после ребута)" else "Нет root")
            refresh()
        }
    }

    fun toggle(id: String, enable: Boolean) {
        viewModelScope.launch {
            val sub = if (enable) "enable" else "disable"
            rootExec("$ksud module $sub '$id'")
            refresh()
        }
    }

    init { refresh() }
}
