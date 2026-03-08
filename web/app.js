const STATUS_LABELS = {
    update_available: '可更新',
    updated: '已更新',
    up_to_date: '已最新',
    whitelist_skipped: '白名单跳过',
    non_git: '非 Git',
    no_upstream: '无上游',
    remote_unreachable: '远程不可访问',
    update_failed: '更新失败',
    deleted: '已删除',
    delete_failed: '删除失败',
    not_found: '目录不存在',
};

const SOURCE_LABELS = {
    public: '公共扩展',
    user: '用户扩展',
};

const NAME_SOURCE_LABELS = {
    metadata: '元数据优先',
    override: '映射兜底',
    directory: '目录名回退',
};

const state = {
    plugins: [],
    filteredPlugins: [],
    whitelist: [],
    settings: null,
    context: null,
    summary: null,
    selectedNames: new Set(),
    pendingActions: 0,
    statusCatalog: Object.entries(STATUS_LABELS).map(([value, label]) => ({ value, label })),
    sourceCatalog: Object.entries(SOURCE_LABELS).map(([value, label]) => ({ value, label })),
    settingsDirty: false,
};

const refs = {
    refreshButton: document.getElementById('refresh-button'),
    updateAllButton: document.getElementById('update-all-button'),
    searchInput: document.getElementById('search-input'),
    statusFilter: document.getElementById('status-filter'),
    sourceFilter: document.getElementById('source-filter'),
    selectVisibleButton: document.getElementById('select-visible-button'),
    clearSelectionButton: document.getElementById('clear-selection-button'),
    batchUpdateButton: document.getElementById('batch-update-button'),
    selectionCount: document.getElementById('selection-count'),
    pluginCountLabel: document.getElementById('plugin-count-label'),
    pluginList: document.getElementById('plugin-list'),
    emptyState: document.getElementById('empty-state'),
    whitelistTags: document.getElementById('whitelist-tags'),
    whitelistCount: document.getElementById('whitelist-count'),
    resultPanel: document.getElementById('result-panel'),
    contextBar: document.getElementById('context-bar'),
    settingsForm: document.getElementById('settings-form'),
    settingDefaultUserName: document.getElementById('setting-default-user-name'),
    settingDefaultStRoot: document.getElementById('setting-default-st-root'),
    settingAutoCheck: document.getElementById('setting-auto-check'),
    summaryTotal: document.getElementById('summary-total'),
    summaryUpdatable: document.getElementById('summary-updatable'),
    summaryUpToDate: document.getElementById('summary-up-to-date'),
    summarySkipped: document.getElementById('summary-skipped'),
    summaryFailed: document.getElementById('summary-failed'),
    template: document.getElementById('plugin-card-template'),
};

function escapeHtml(value) {
    return String(value ?? '')
        .replace(/&/g, '&' + 'amp;')
        .replace(/</g, '&' + 'lt;')
        .replace(/>/g, '&' + 'gt;')
        .replace(/"/g, '&' + 'quot;')
        .replace(/'/g, '&' + '#39;');
}

function normalizeText(value) {
    return String(value ?? '').trim().toLowerCase();
}

function setBusy(isBusy) {
    if (isBusy) {
        state.pendingActions += 1;
    } else {
        state.pendingActions = Math.max(0, state.pendingActions - 1);
    }

    const disabled = state.pendingActions > 0;
    [
        refs.refreshButton,
        refs.updateAllButton,
        refs.selectVisibleButton,
        refs.clearSelectionButton,
        refs.batchUpdateButton,
    ].forEach((button) => {
        if (button) button.disabled = disabled;
    });

    const actionButtons = refs.pluginList.querySelectorAll('button');
    actionButtons.forEach((button) => {
        button.disabled = disabled;
    });
}

async function withBusy(task) {
    setBusy(true);
    try {
        return await task();
    } finally {
        setBusy(false);
    }
}

async function requestJson(url, options = {}) {
    let response;
    try {
        response = await fetch(url, {
            headers: {
                'Content-Type': 'application/json',
                ...(options.headers || {}),
            },
            ...options,
        });
    } catch (error) {
        const message = error instanceof Error ? error.message : '网络请求失败';
        throw {
            code: 'network_error',
            message: '无法连接本地 Web 面板后端',
            details: message,
            status: 0,
        };
    }

    let payload = null;
    try {
        payload = await response.json();
    } catch (error) {
        throw {
            code: 'invalid_response',
            message: '服务器返回了无法解析的 JSON',
            details: error instanceof Error ? error.message : String(error),
            status: response.status,
        };
    }

    if (!response.ok || !payload.ok) {
        const error = payload && payload.error ? payload.error : {};
        throw {
            code: error.code || 'request_failed',
            message: error.message || `请求失败（HTTP ${response.status}）`,
            details: error.details ?? null,
            status: response.status,
        };
    }

    return payload.data;
}

function buildContextPayload() {
    const payload = {};
    const stRoot = refs.settingDefaultStRoot.value.trim();
    const userName = refs.settingDefaultUserName.value.trim();

    if (stRoot) payload.st_root = stRoot;
    if (userName) payload.user_name = userName;

    return payload;
}

function buildContextQuery() {
    const payload = buildContextPayload();
    const params = new URLSearchParams();
    if (payload.st_root) params.set('st_root', payload.st_root);
    if (payload.user_name) params.set('user_name', payload.user_name);
    const query = params.toString();
    return query ? `?${query}` : '';
}

function buildSettingsPayload() {
    return {
        default_user_name: refs.settingDefaultUserName.value.trim(),
        default_st_root: refs.settingDefaultStRoot.value.trim(),
        auto_check_on_start: refs.settingAutoCheck.checked,
    };
}

function renderSelectOptions(selectElement, items, allLabel) {
    const currentValue = selectElement.value;
    selectElement.innerHTML = '';

    const allOption = document.createElement('option');
    allOption.value = '';
    allOption.textContent = allLabel;
    selectElement.appendChild(allOption);

    items.forEach((item) => {
        const option = document.createElement('option');
        option.value = item.value;
        option.textContent = item.label;
        selectElement.appendChild(option);
    });

    if ([...selectElement.options].some((option) => option.value === currentValue)) {
        selectElement.value = currentValue;
    }
}

function renderCatalogs() {
    renderSelectOptions(refs.statusFilter, state.statusCatalog, '全部状态');
    renderSelectOptions(refs.sourceFilter, state.sourceCatalog, '全部来源');
}

function renderSummary(summary) {
    refs.summaryTotal.textContent = String(summary?.total ?? 0);
    refs.summaryUpdatable.textContent = String(summary?.updatable ?? 0);
    refs.summaryUpToDate.textContent = String(summary?.up_to_date ?? 0);
    refs.summarySkipped.textContent = String(summary?.skipped ?? 0);
    refs.summaryFailed.textContent = String(summary?.failed ?? 0);
}

function renderContextBar() {
    const parts = [];
    if (state.context?.st_root) {
        parts.push(`当前根目录：${state.context.st_root}`);
    }
    if (state.context?.user_name) {
        parts.push(`当前用户：${state.context.user_name}`);
    }
    if (state.settings?.effective_default_st_root) {
        parts.push(`默认根目录：${state.settings.effective_default_st_root}`);
    }
    parts.push('友好名顺序：元数据 → 映射文件 → 目录名');
    refs.contextBar.textContent = parts.join(' ｜ ');
}

function nameSourceText(plugin) {
    const label = NAME_SOURCE_LABELS[plugin.display_name_source] || plugin.display_name_source || '目录名回退';
    if (plugin.display_name_detail) {
        return `${label}：${plugin.display_name_detail}`;
    }
    return label;
}

function updateSelectionCount() {
    refs.selectionCount.textContent = `已选 ${state.selectedNames.size} 项`;
}

function getVisiblePluginNames() {
    return state.filteredPlugins.map((plugin) => plugin.directory_name);
}

function retainExistingSelection() {
    const validNames = new Set(state.plugins.map((plugin) => plugin.directory_name));
    state.selectedNames.forEach((name) => {
        if (!validNames.has(name)) {
            state.selectedNames.delete(name);
        }
    });
}

function matchesFilters(plugin) {
    const keyword = normalizeText(refs.searchInput.value);
    const statusFilter = refs.statusFilter.value;
    const sourceFilter = refs.sourceFilter.value;

    if (keyword) {
        const haystack = [
            plugin.display_name,
            plugin.directory_name,
            plugin.source_label,
            plugin.reason,
        ]
            .join(' ')
            .toLowerCase();
        if (!haystack.includes(keyword)) {
            return false;
        }
    }

    if (statusFilter && plugin.status !== statusFilter) {
        return false;
    }

    if (sourceFilter && plugin.source !== sourceFilter) {
        return false;
    }

    return true;
}

function renderPluginList() {
    state.filteredPlugins = state.plugins.filter(matchesFilters);
    refs.pluginList.innerHTML = '';

    refs.pluginCountLabel.textContent = `当前显示 ${state.filteredPlugins.length} / ${state.plugins.length} 项`;
    refs.emptyState.classList.toggle('hidden', state.filteredPlugins.length > 0);

    state.filteredPlugins.forEach((plugin) => {
        const fragment = refs.template.content.cloneNode(true);
        const article = fragment.querySelector('.plugin-card');
        const checkbox = fragment.querySelector('.plugin-checkbox');
        const title = fragment.querySelector('.plugin-title');
        const directory = fragment.querySelector('.plugin-directory');
        const statusBadge = fragment.querySelector('.status-badge');
        const sourceChip = fragment.querySelector('.source-chip');
        const nameSourceChip = fragment.querySelector('.name-source-chip');
        const whitelistChip = fragment.querySelector('.whitelist-chip');
        const reason = fragment.querySelector('.plugin-reason');
        const singleUpdateButton = fragment.querySelector('.action-single-update');
        const whitelistButton = fragment.querySelector('.action-whitelist');
        const deleteButton = fragment.querySelector('.action-delete');

        article.dataset.pluginName = plugin.directory_name;
        title.textContent = plugin.display_name || plugin.directory_name;
        directory.textContent = `目录名：${plugin.directory_name}`;
        statusBadge.textContent = plugin.status_label || STATUS_LABELS[plugin.status] || plugin.status;
        statusBadge.classList.add(`status-${plugin.status}`);
        sourceChip.textContent = plugin.source_label || SOURCE_LABELS[plugin.source] || plugin.source || '未知来源';
        nameSourceChip.textContent = nameSourceText(plugin);
        reason.textContent = plugin.reason || plugin.status_label || '无附加说明';

        checkbox.checked = state.selectedNames.has(plugin.directory_name);
        checkbox.addEventListener('change', () => {
            if (checkbox.checked) {
                state.selectedNames.add(plugin.directory_name);
            } else {
                state.selectedNames.delete(plugin.directory_name);
            }
            updateSelectionCount();
        });

        if (plugin.whitelisted) {
            whitelistChip.classList.remove('hidden');
            whitelistButton.textContent = '移出白名单';
        } else {
            whitelistChip.classList.add('hidden');
            whitelistButton.textContent = '加入白名单';
        }

        singleUpdateButton.addEventListener('click', () => handleUpdateSelected([plugin.directory_name], `单独更新：${plugin.display_name}`));
        whitelistButton.addEventListener('click', () => handleWhitelistToggle(plugin));
        deleteButton.addEventListener('click', () => handleDelete([plugin.directory_name], plugin.display_name));

        refs.pluginList.appendChild(fragment);
    });

    updateSelectionCount();
}

function renderWhitelist(items) {
    state.whitelist = Array.isArray(items) ? items : [];
    refs.whitelistCount.textContent = `${state.whitelist.length} 项`;
    refs.whitelistTags.innerHTML = '';

    if (state.whitelist.length === 0) {
        const span = document.createElement('span');
        span.className = 'tag-item tag-item-empty';
        span.textContent = '当前白名单为空';
        refs.whitelistTags.appendChild(span);
        return;
    }

    state.whitelist.forEach((name) => {
        const span = document.createElement('span');
        span.className = 'tag-item';
        span.textContent = name;
        refs.whitelistTags.appendChild(span);
    });
}

function applySettings(settings, force = false) {
    state.settings = settings || {};
    if (force || !state.settingsDirty) {
        refs.settingDefaultUserName.value = state.settings.default_user_name || '';
        refs.settingDefaultStRoot.value = state.settings.default_st_root || '';
        refs.settingAutoCheck.checked = Boolean(state.settings.auto_check_on_start);
        state.settingsDirty = false;
    }
    renderContextBar();
}

function applyOverview(data) {
    state.context = data.context || null;
    state.summary = data.summary || null;
    state.statusCatalog = Array.isArray(data.status_catalog) && data.status_catalog.length > 0 ? data.status_catalog : state.statusCatalog;
    state.sourceCatalog = Array.isArray(data.source_catalog) && data.source_catalog.length > 0 ? data.source_catalog : state.sourceCatalog;
    state.plugins = Array.isArray(data.plugins) ? data.plugins : [];
    retainExistingSelection();
    renderCatalogs();
    renderSummary(state.summary || {});
    renderContextBar();
    renderPluginList();
}

function renderResultHtml(title, groups = []) {
    const html = groups
        .map((group) => {
            const listItems = Array.isArray(group.items)
                ? group.items.map((item) => `<li>${item}</li>`).join('')
                : '';
            return `
                <section class="result-group">
                    <h3>${escapeHtml(group.title || title)}</h3>
                    ${group.description ? `<p>${escapeHtml(group.description)}</p>` : ''}
                    ${listItems ? `<ul class="result-list">${listItems}</ul>` : ''}
                </section>
            `;
        })
        .join('');

    refs.resultPanel.classList.remove('muted-text');
    refs.resultPanel.innerHTML = `
        <div class="result-group">
            <h3>${escapeHtml(title)}</h3>
        </div>
        ${html}
    `;
}

function renderInfo(message) {
    refs.resultPanel.classList.remove('muted-text');
    refs.resultPanel.textContent = message;
}

function renderError(error) {
    const details = error?.details;
    const detailText = typeof details === 'string'
        ? details
        : details
            ? JSON.stringify(details, null, 2)
            : '无更多信息';

    renderResultHtml('操作失败', [
        {
            title: error?.message || '请求失败',
            items: [
                `错误代码：${escapeHtml(error?.code || 'unknown_error')}`,
                `详情：${escapeHtml(detailText)}`,
            ],
        },
    ]);
}

function summarizeUpdateResults(title, data) {
    const summary = data.summary || {};
    const results = Array.isArray(data.results) ? data.results : [];
    renderResultHtml(title, [
        {
            title: '汇总',
            items: [
                `已检查：${summary.checked ?? 0}`,
                `已更新：${summary.updated ?? 0}`,
                `已最新：${summary.up_to_date ?? 0}`,
                `已跳过：${summary.skipped ?? 0}`,
                `失败：${summary.failed ?? 0}`,
            ],
        },
        {
            title: '结果明细',
            items: results.map((item) => `${escapeHtml(item.display_name)}（${escapeHtml(item.directory_name)}）｜${escapeHtml(item.status_label || item.status)}｜${escapeHtml(item.reason || '')}`),
        },
    ]);
}

function summarizeWhitelistResult(title, data) {
    const results = Array.isArray(data.results) ? data.results : [];
    renderResultHtml(title, [
        {
            title: '执行结果',
            items: results.map((item) => `${escapeHtml(item.name)}｜${escapeHtml(item.status)}｜${escapeHtml(item.message || '')}`),
        },
        {
            title: '最新白名单',
            items: (data.items || []).length > 0 ? data.items.map((item) => escapeHtml(item)) : ['当前白名单为空'],
        },
    ]);
}

function summarizeDeleteResult(title, data) {
    const summary = data.summary || {};
    const results = Array.isArray(data.results) ? data.results : [];
    renderResultHtml(title, [
        {
            title: '删除统计',
            items: [
                `成功删除：${summary.deleted ?? 0}`,
                `失败：${summary.failed ?? 0}`,
                `跳过：${summary.skipped ?? 0}`,
            ],
        },
        {
            title: '删除明细',
            items: results.map((item) => `${escapeHtml(item.display_name || item.directory_name)}（${escapeHtml(item.directory_name)}）｜${escapeHtml(item.status_label || item.status)}｜${escapeHtml(item.reason || '')}`),
        },
    ]);
}

function summarizeSettingsResult(data) {
    const settings = data.settings || {};
    renderResultHtml('设置已保存', [
        {
            title: '当前设置',
            items: [
                `默认用户名：${escapeHtml(settings.default_user_name || '')}`,
                `默认根目录：${escapeHtml(settings.default_st_root || '未设置（自动检测）')}`,
                `自动检测更新：${settings.auto_check_on_start ? '已开启' : '已关闭'}`,
                `Termux 环境：${data.termux_environment ? '是' : '否'}`,
                `启动项文件是否改动：${data.shell_updated ? '已修改' : '未修改'}`,
            ],
        },
    ]);
}

async function loadSettingsOnly(force = false) {
    const data = await requestJson('/api/settings');
    applySettings(data.settings || {}, force);
}

async function loadWhitelistOnly() {
    const data = await requestJson('/api/whitelist');
    renderWhitelist(data.items || []);
}

async function loadOverviewOnly() {
    const data = await requestJson(`/api/overview${buildContextQuery()}`);
    applyOverview(data);
}

async function initializePanel() {
    renderCatalogs();
    renderSummary({ total: 0, updatable: 0, up_to_date: 0, skipped: 0, failed: 0 });
    renderWhitelist([]);
    renderInfo('正在加载面板数据...');

    try {
        await withBusy(async () => {
            await loadSettingsOnly(true);
            await loadWhitelistOnly();
            await loadOverviewOnly();
        });
        renderInfo('面板已加载完成。');
    } catch (error) {
        renderError(error);
    }
}

async function refreshPanel(message = '面板已刷新。') {
    try {
        await withBusy(async () => {
            await loadWhitelistOnly();
            await loadOverviewOnly();
        });
        renderInfo(message);
    } catch (error) {
        renderError(error);
    }
}

async function handleUpdateAll() {
    if (!window.confirm('确认对当前上下文中的全部插件执行更新吗？')) {
        return;
    }

    try {
        const data = await withBusy(() => requestJson('/api/update-all', {
            method: 'POST',
            body: JSON.stringify(buildContextPayload()),
        }));
        summarizeUpdateResults('一键更新完成', data);
        await loadOverviewOnly();
        await loadWhitelistOnly();
    } catch (error) {
        renderError(error);
    }
}

async function handleUpdateSelected(pluginNames, title = '批量更新完成') {
    if (!Array.isArray(pluginNames) || pluginNames.length === 0) {
        renderInfo('请先选择至少一个插件。');
        return;
    }

    try {
        const data = await withBusy(() => requestJson('/api/update-selected', {
            method: 'POST',
            body: JSON.stringify({
                ...buildContextPayload(),
                plugins: pluginNames,
            }),
        }));
        summarizeUpdateResults(title, data);
        await loadOverviewOnly();
        await loadWhitelistOnly();
    } catch (error) {
        renderError(error);
    }
}

async function handleWhitelistToggle(plugin) {
    const action = plugin.whitelisted ? 'remove' : 'add';
    const title = plugin.whitelisted ? '已移出白名单' : '已加入白名单';

    try {
        const data = await withBusy(() => requestJson('/api/whitelist', {
            method: 'POST',
            body: JSON.stringify({
                action,
                plugins: [plugin.directory_name],
            }),
        }));
        summarizeWhitelistResult(title, data);
        renderWhitelist(data.items || []);
        await loadOverviewOnly();
    } catch (error) {
        renderError(error);
    }
}

async function handleDelete(pluginNames, displayText = '') {
    const listText = Array.isArray(pluginNames) ? pluginNames.join('、') : '';
    const confirmText = displayText
        ? `确认删除插件：${displayText} 吗？`
        : `确认删除这些插件吗？\n${listText}`;

    if (!window.confirm(confirmText)) {
        return;
    }

    try {
        const data = await withBusy(() => requestJson('/api/delete', {
            method: 'POST',
            body: JSON.stringify({
                ...buildContextPayload(),
                plugins: pluginNames,
            }),
        }));
        pluginNames.forEach((name) => state.selectedNames.delete(name));
        summarizeDeleteResult('删除操作完成', data);
        await loadOverviewOnly();
        await loadWhitelistOnly();
    } catch (error) {
        renderError(error);
    }
}

async function handleSaveSettings(event) {
    event.preventDefault();

    try {
        const data = await withBusy(() => requestJson('/api/settings', {
            method: 'POST',
            body: JSON.stringify(buildSettingsPayload()),
        }));
        applySettings(data.settings || {}, true);
        summarizeSettingsResult(data);
        await loadOverviewOnly();
    } catch (error) {
        renderError(error);
    }
}

function handleSelectVisible() {
    getVisiblePluginNames().forEach((name) => state.selectedNames.add(name));
    renderPluginList();
}

function handleClearSelection() {
    state.selectedNames.clear();
    renderPluginList();
}

function bindEvents() {
    refs.refreshButton.addEventListener('click', () => refreshPanel());
    refs.updateAllButton.addEventListener('click', handleUpdateAll);
    refs.selectVisibleButton.addEventListener('click', handleSelectVisible);
    refs.clearSelectionButton.addEventListener('click', handleClearSelection);
    refs.batchUpdateButton.addEventListener('click', () => handleUpdateSelected([...state.selectedNames], '批量更新完成'));
    refs.searchInput.addEventListener('input', renderPluginList);
    refs.statusFilter.addEventListener('change', renderPluginList);
    refs.sourceFilter.addEventListener('change', renderPluginList);
    refs.settingsForm.addEventListener('submit', handleSaveSettings);

    [refs.settingDefaultUserName, refs.settingDefaultStRoot, refs.settingAutoCheck].forEach((element) => {
        element.addEventListener('input', () => {
            state.settingsDirty = true;
        });
        element.addEventListener('change', () => {
            state.settingsDirty = true;
        });
    });
}

bindEvents();
initializePanel();
