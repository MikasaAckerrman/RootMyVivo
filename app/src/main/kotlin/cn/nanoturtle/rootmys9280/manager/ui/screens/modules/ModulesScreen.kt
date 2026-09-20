package cn.nanoturtle.rootmys9280.manager.ui.screens.modules

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import java.io.File

/**
 * ModulesScreen — менеджер модулей ownroot (v1: CLI через libksud.dm).
 * v2 (план): интеграция libksud JNI + полноценный UI уровня SukiSU.
 */
@Composable
fun ModulesScreen(vm: ModulesViewModel = viewModel()) {
    val state by vm.state.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current

    val zipPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri != null) {
            val cache = File(context.cacheDir, "module_install.zip")
            vm.install(uri, cache)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Модули") },
                actions = {
                    IconButton(onClick = { vm.refresh() }) {
                        Icon(Icons.Rounded.Refresh, contentDescription = "Обновить")
                    }
                },
            )
        },
        floatingActionButton = {
            if (state.hasRoot) {
                ExtendedFloatingActionButton(
                    onClick = { zipPicker.launch(arrayOf("application/zip")) },
                ) { Text("Установить ZIP") }
            }
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
        ) {
            if (state.message.isNotEmpty()) {
                Text(
                    state.message,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (state.hasRoot) MaterialTheme.colorScheme.onSurfaceVariant
                            else MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            }
            if (state.loading) {
                Row(
                    Modifier.fillMaxWidth().padding(16.dp),
                    horizontalArrangement = Arrangement.Center,
                ) { CircularProgressIndicator() }
            }
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(state.modules, key = { it.id }) { m ->
                    Card(
                        colors = CardDefaults.cardColors(
                            containerColor = if (m.enabled)
                                MaterialTheme.colorScheme.surfaceVariant
                            else MaterialTheme.colorScheme.surfaceDim,
                        ),
                    ) {
                        Row(
                            Modifier.fillMaxWidth().padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(m.name, style = MaterialTheme.typography.titleSmall)
                                Text(
                                    "${m.id} · ${m.version}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Switch(
                                checked = m.enabled,
                                onCheckedChange = { vm.toggle(m.id, it) },
                            )
                            IconButton(onClick = { vm.uninstall(m.id) }) {
                                Icon(
                                    Icons.Rounded.Delete,
                                    contentDescription = "Удалить ${m.id}",
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
