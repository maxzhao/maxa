<template>
  <q-page class="q-pa-md">
    <div class="row q-mb-md">
      <div class="col">
        <div class="text-h4">用户角色管理</div>
        <div class="text-caption text-grey-7">为用户分配和管理角色权限</div>
      </div>
      <div class="col-auto q-gutter-sm">
        <q-btn
          v-if="selected.length > 0"
          color="primary"
          icon="people"
          label="批量分配角色"
          @click="openBatchAssignDialog"
        />
        <q-btn
          v-if="selected.length > 0"
          color="negative"
          icon="remove_circle"
          label="批量移除角色"
          @click="openBatchRemoveDialog"
        />
        <q-btn
          v-if="selected.length > 0"
          color="info"
          icon="download"
          label="导出用户列表"
          @click="exportUserList"
        />
      </div>
    </div>

    <!-- 搜索和过滤 -->
    <q-card flat bordered class="q-mb-md">
      <q-card-section>
        <div class="row q-col-gutter-md">
          <div class="col-12 col-md-4">
            <q-input
              v-model="searchQuery"
              outlined
              dense
              placeholder="搜索用户名或邮箱..."
              clearable
              @update:model-value="handleSearch"
            >
              <template #prepend>
                <q-icon name="search" />
              </template>
            </q-input>
          </div>
          <div class="col-12 col-md-3">
            <q-select
              v-model="roleFilter"
              :options="roleFilterOptions"
              outlined
              dense
              clearable
              label="按角色过滤"
              emit-value
              map-options
              @update:model-value="handleFilter"
            />
          </div>
          <div class="col-12 col-md-3">
            <q-select
              v-model="statusFilter"
              :options="statusFilterOptions"
              outlined
              dense
              clearable
              label="在线状态"
              emit-value
              map-options
              @update:model-value="handleFilter"
            />
          </div>
          <div class="col-12 col-md-2">
            <q-btn
              outline
              color="primary"
              icon="refresh"
              label="刷新"
              class="full-width"
              @click="loadUsers"
            />
          </div>
        </div>
      </q-card-section>
    </q-card>

    <!-- 用户列表 -->
    <q-card flat bordered>
      <q-table
        v-model:selected="selected"
        :rows="filteredUsers"
        :columns="columns"
        :loading="rbacStore.loading"
        :pagination="pagination"
        row-key="id"
        selection="multiple"
        flat
        @request="onTableRequest"
      >
        <template #body-cell-username="props">
          <q-td :props="props">
            <div class="row items-center q-gutter-sm">
              <q-avatar color="primary" text-color="white" size="32px">
                {{ props.row.username[0].toUpperCase() }}
              </q-avatar>
              <div>
                <div>{{ props.row.username }}</div>
                <div class="text-caption text-grey-7">
                  {{ props.row.email }}
                </div>
              </div>
            </div>
          </q-td>
        </template>

        <template #body-cell-roles="props">
          <q-td :props="props">
            <q-chip
              v-for="role in props.row.roles"
              :key="role.id"
              dense
              size="sm"
              :color="getRoleColor(role.id)"
              text-color="white"
            >
              {{ role.name }}
            </q-chip>
            <!-- 临时角色显示 -->
            <q-chip
              v-for="tempRole in props.row.temporary_roles"
              :key="tempRole.role_id"
              dense
              size="sm"
              color="orange"
              text-color="white"
              icon="schedule"
            >
              {{ tempRole.role_name }}
              <q-tooltip>
                到期时间：{{ formatDate(tempRole.expires_at) }}
              </q-tooltip>
            </q-chip>
          </q-td>
        </template>

        <template #body-cell-last_login="props">
          <q-td :props="props">
            <div class="row items-center q-gutter-sm">
              <q-badge
                v-if="props.row.is_online"
                color="positive"
                label="在线"
              />
              <q-badge v-else color="grey" label="离线" />
              <span class="text-caption">{{
                props.row.last_login
                  ? formatDate(props.row.last_login)
                  : "从未登录"
              }}</span>
            </div>
          </q-td>
        </template>

        <template #body-cell-actions="props">
          <q-td :props="props">
            <q-btn
              flat
              round
              dense
              icon="edit"
              @click="openAssignRoleDialog(props.row)"
            >
              <q-tooltip>分配角色</q-tooltip>
            </q-btn>
            <q-btn
              flat
              round
              dense
              icon="schedule"
              @click="openTemporaryRoleDialog(props.row)"
            >
              <q-tooltip>设置临时角色</q-tooltip>
            </q-btn>
            <q-btn
              flat
              round
              dense
              icon="history"
              @click="viewRoleHistory(props.row)"
            >
              <q-tooltip>查看变更历史</q-tooltip>
            </q-btn>
          </q-td>
        </template>
      </q-table>
    </q-card>

    <!-- 单用户角色分配对话框 -->
    <q-dialog v-model="showAssignDialog">
      <q-card style="min-width: 500px">
        <q-card-section>
          <div class="text-h6">分配角色</div>
          <div class="text-caption text-grey-7">
            用户：{{ selectedUser?.username }} ({{ selectedUser?.email }})
          </div>
        </q-card-section>

        <q-separator />

        <q-card-section class="q-pt-md">
          <div class="q-mb-md">
            <div class="text-subtitle2 q-mb-sm">当前角色</div>
            <q-chip
              v-for="role in selectedUser?.roles"
              :key="role.id"
              dense
              removable
              :color="getRoleColor(role.id)"
              text-color="white"
              @remove="removeUserRole(role.id)"
            >
              {{ role.name }}
            </q-chip>
            <span
              v-if="!selectedUser?.roles || selectedUser.roles.length === 0"
              class="text-grey-5"
              >暂无角色</span
            >
          </div>

          <q-select
            v-model="selectedRoles"
            :options="roleOptions"
            label="选择要分配的角色"
            multiple
            outlined
            use-chips
            stack-label
            emit-value
            map-options
          >
            <template #prepend>
              <q-icon name="search" />
            </template>
          </q-select>

          <div v-if="selectedRoles.length > 0" class="q-mt-md">
            <div class="text-subtitle2 q-mb-sm">将要分配的角色</div>
            <q-chip
              v-for="roleId in selectedRoles"
              :key="roleId"
              dense
              :color="getRoleColor(roleId)"
              text-color="white"
            >
              {{ getRoleName(roleId) }}
            </q-chip>
          </div>
        </q-card-section>

        <q-separator />

        <q-card-actions align="right">
          <q-btn flat label="取消" @click="showAssignDialog = false" />
          <q-btn
            color="primary"
            label="保存"
            :loading="rbacStore.loading"
            @click="saveRoleAssignment"
          />
        </q-card-actions>
      </q-card>
    </q-dialog>

    <!-- 批量角色分配对话框 -->
    <q-dialog v-model="showBatchAssignDialog">
      <q-card style="min-width: 500px">
        <q-card-section>
          <div class="text-h6">批量分配角色</div>
          <div class="text-caption text-grey-7">
            已选择 {{ selected.length }} 个用户
          </div>
        </q-card-section>

        <q-separator />

        <q-card-section class="q-pt-md">
          <q-select
            v-model="batchSelectedRoles"
            :options="roleOptions"
            label="选择要分配的角色"
            multiple
            outlined
            use-chips
            stack-label
            emit-value
            map-options
          />

          <q-banner
            v-if="selected.length > 0 && batchSelectedRoles.length > 0"
            class="bg-info text-white q-mt-md"
          >
            将为 <strong>{{ selected.length }}</strong> 个用户分配
            <strong>{{ batchSelectedRoles.length }}</strong> 个角色
          </q-banner>

          <q-linear-progress
            v-if="batchProgress.show"
            :value="batchProgress.value"
            class="q-mt-md"
            color="primary"
          >
            <div class="absolute-full flex flex-center">
              <q-badge
                color="white"
                text-color="primary"
                :label="`${Math.floor(batchProgress.value * 100)}%`"
              />
            </div>
          </q-linear-progress>
        </q-card-section>

        <q-separator />

        <q-card-actions align="right">
          <q-btn
            flat
            label="取消"
            :disable="batchProgress.show"
            @click="showBatchAssignDialog = false"
          />
          <q-btn
            color="primary"
            label="批量分配"
            :loading="rbacStore.loading"
            :disable="batchSelectedRoles.length === 0"
            @click="saveBatchAssignment"
          />
        </q-card-actions>
      </q-card>
    </q-dialog>

    <!-- 临时角色设置对话框 -->
    <q-dialog v-model="showTemporaryRoleDialog">
      <q-card style="min-width: 500px">
        <q-card-section>
          <div class="text-h6">设置临时角色</div>
          <div class="text-caption text-grey-7">
            用户：{{ selectedUser?.username }} ({{ selectedUser?.email }})
          </div>
        </q-card-section>

        <q-separator />

        <q-card-section class="q-pt-md">
          <q-select
            v-model="temporaryRoleId"
            :options="roleOptions"
            label="选择角色"
            outlined
            emit-value
            map-options
          />

          <div class="q-mt-md">
            <div class="text-subtitle2 q-mb-sm">过期时间</div>
            <div class="row q-col-gutter-sm q-mb-md">
              <div class="col">
                <q-btn outline label="1小时" @click="setExpiresPreset(1)" />
              </div>
              <div class="col">
                <q-btn outline label="1天" @click="setExpiresPreset(24)" />
              </div>
              <div class="col">
                <q-btn outline label="7天" @click="setExpiresPreset(24 * 7)" />
              </div>
              <div class="col">
                <q-btn
                  outline
                  label="30天"
                  @click="setExpiresPreset(24 * 30)"
                />
              </div>
            </div>

            <q-input
              v-model="temporaryRoleExpires"
              type="datetime-local"
              outlined
              label="自定义过期时间"
            />
          </div>

          <q-input
            v-model="temporaryRoleReason"
            type="textarea"
            outlined
            label="原因（可选）"
            rows="3"
            class="q-mt-md"
          />
        </q-card-section>

        <q-separator />

        <q-card-actions align="right">
          <q-btn flat label="取消" @click="showTemporaryRoleDialog = false" />
          <q-btn
            color="primary"
            label="设置"
            :loading="rbacStore.loading"
            :disable="!temporaryRoleId || !temporaryRoleExpires"
            @click="saveTemporaryRole"
          />
        </q-card-actions>
      </q-card>
    </q-dialog>

    <!-- 角色变更历史对话框 -->
    <q-dialog v-model="showHistoryDialog">
      <q-card style="min-width: 600px; max-width: 800px">
        <q-card-section>
          <div class="text-h6">角色变更历史</div>
          <div class="text-caption text-grey-7">
            用户：{{ selectedUser?.username }} ({{ selectedUser?.email }})
          </div>
        </q-card-section>

        <q-separator />

        <q-card-section class="q-pt-md">
          <div class="row q-mb-md q-gutter-sm">
            <q-btn-toggle
              v-model="historyTimeRange"
              toggle-color="primary"
              :options="[
                { label: '最近7天', value: 7 },
                { label: '最近30天', value: 30 },
                { label: '全部', value: 0 },
              ]"
              @update:model-value="loadRoleHistory"
            />
            <q-space />
            <q-btn
              outline
              color="primary"
              icon="download"
              label="导出CSV"
              @click="exportHistory"
            />
          </div>

          <q-timeline v-if="roleHistory.length > 0" color="primary">
            <q-timeline-entry
              v-for="entry in filteredHistory"
              :key="entry.id"
              :title="entry.role_name"
              :subtitle="formatDate(entry.timestamp)"
              :icon="
                entry.action === 'assigned' ? 'add_circle' : 'remove_circle'
              "
              :color="entry.action === 'assigned' ? 'positive' : 'negative'"
            >
              <div>
                <strong>{{
                  entry.action === "assigned" ? "分配" : "移除"
                }}</strong>
              </div>
              <div v-if="entry.operator_name" class="text-caption">
                操作人：{{ entry.operator_name }}
              </div>
              <div v-if="entry.reason" class="text-caption">
                原因：{{ entry.reason }}
              </div>
            </q-timeline-entry>
          </q-timeline>

          <div v-else class="text-center text-grey-6 q-pa-xl">
            <q-icon name="history" size="64px" />
            <div class="q-mt-md">暂无角色变更历史</div>
          </div>
        </q-card-section>

        <q-separator />

        <q-card-actions align="right">
          <q-btn flat label="关闭" @click="showHistoryDialog = false" />
        </q-card-actions>
      </q-card>
    </q-dialog>
  </q-page>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from "vue";
import { useQuasar } from "quasar";
import { useRbacStore } from "@/stores/rbac";
import type {
  UserWithRoles,
  RoleChangeHistoryEntry,
  AssignRoleRequest,
  BatchAssignRolesRequest,
  SetTemporaryRoleRequest,
} from "@/types/api";
import Papa from "papaparse";

const $q = useQuasar();
const rbacStore = useRbacStore();

// 搜索和过滤
const searchQuery = ref("");
const roleFilter = ref<string | null>(null);
const statusFilter = ref<"online" | "offline" | "all">("all");

// 表格选择和分页
const selected = ref<UserWithRoles[]>([]);
const pagination = ref({
  page: 1,
  rowsPerPage: 10,
  rowsNumber: 0,
});

// 对话框状态
const showAssignDialog = ref(false);
const showBatchAssignDialog = ref(false);
const showTemporaryRoleDialog = ref(false);
const showHistoryDialog = ref(false);

// 选中的用户和角色
const selectedUser = ref<UserWithRoles | null>(null);
const selectedRoles = ref<string[]>([]);
const batchSelectedRoles = ref<string[]>([]);

// 临时角色相关
const temporaryRoleId = ref<string>("");
const temporaryRoleExpires = ref<string>("");
const temporaryRoleReason = ref<string>("");

// 角色历史相关
const roleHistory = ref<RoleChangeHistoryEntry[]>([]);
const historyTimeRange = ref<number>(30);

// 批量操作进度
const batchProgress = ref({
  show: false,
  value: 0,
});

// 表格列定义
const columns = [
  {
    name: "username",
    label: "用户",
    field: "username",
    align: "left" as const,
    sortable: true,
  },
  {
    name: "roles",
    label: "角色",
    field: "roles",
    align: "left" as const,
  },
  {
    name: "last_login",
    label: "最后登录",
    field: "last_login",
    align: "center" as const,
    sortable: true,
  },
  {
    name: "actions",
    label: "操作",
    field: "id",
    align: "center" as const,
  },
];

// 过滤后的用户列表
const filteredUsers = computed(() => {
  let users = rbacStore.users;

  // 搜索过滤
  if (searchQuery.value) {
    const query = searchQuery.value.toLowerCase();
    users = users.filter(
      (user) =>
        user.username.toLowerCase().includes(query) ||
        user.email.toLowerCase().includes(query),
    );
  }

  // 角色过滤
  if (roleFilter.value) {
    users = users.filter((user) =>
      user.role_ids?.includes(roleFilter.value as string),
    );
  }

  // 在线状态过滤
  if (statusFilter.value !== "all") {
    const isOnline = statusFilter.value === "online";
    users = users.filter((user) => user.is_online === isOnline);
  }

  return users;
});

// 过滤后的历史记录
const filteredHistory = computed(() => {
  if (historyTimeRange.value === 0) {
    return roleHistory.value;
  }

  const cutoffDate = new Date();
  cutoffDate.setDate(cutoffDate.getDate() - historyTimeRange.value);

  return roleHistory.value.filter(
    (entry) => new Date(entry.timestamp) >= cutoffDate,
  );
});

// 角色选项
const roleOptions = computed(() => rbacStore.roleOptions);

// 角色过滤选项
const roleFilterOptions = computed(() => [
  { label: "所有角色", value: null },
  ...rbacStore.roleOptions,
]);

// 状态过滤选项
const statusFilterOptions = [
  { label: "全部", value: "all" },
  { label: "在线", value: "online" },
  { label: "离线", value: "offline" },
];

/**
 * 获取角色颜色
 */
function getRoleColor(roleId: string): string {
  const colors = [
    "primary",
    "secondary",
    "accent",
    "info",
    "positive",
    "warning",
  ];
  const index = roleId.charCodeAt(0) % colors.length;
  return colors[index];
}

/**
 * 获取角色名称
 */
function getRoleName(roleId: string): string {
  return rbacStore.getRoleById(roleId)?.name || "未知角色";
}

/**
 * 格式化日期
 */
function formatDate(date: string): string {
  return new Date(date).toLocaleString("zh-CN");
}

/**
 * 处理搜索
 */
function handleSearch() {
  // 搜索是响应式的，filteredUsers会自动更新
  pagination.value.page = 1;
}

/**
 * 处理过滤
 */
function handleFilter() {
  pagination.value.page = 1;
}

/**
 * 表格请求处理
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function onTableRequest(props: any) {
  pagination.value = props.pagination;
}

/**
 * 加载用户列表
 */
async function loadUsers() {
  try {
    await rbacStore.fetchUsers();
    pagination.value.rowsNumber = rbacStore.usersTotal;
  } catch (error) {
    console.error("加载用户列表失败:", error);
    $q.notify({
      type: "negative",
      message: "加载用户列表失败",
    });
  }
}

/**
 * 打开角色分配对话框
 */
function openAssignRoleDialog(user: UserWithRoles) {
  selectedUser.value = user;
  selectedRoles.value = [];
  showAssignDialog.value = true;
}

/**
 * 移除用户角色
 */
async function removeUserRole(roleId: string) {
  if (!selectedUser.value) return;

  try {
    await rbacStore.removeRoleFromUser(selectedUser.value.id, roleId);
    $q.notify({
      type: "positive",
      message: "角色移除成功",
    });
    // 更新选中用户的信息
    selectedUser.value =
      rbacStore.users.find((u) => u.id === selectedUser.value?.id) || null;
  } catch (error) {
    console.error("移除角色失败:", error);
    $q.notify({
      type: "negative",
      message: "移除角色失败",
    });
  }
}

/**
 * 保存角色分配
 */
async function saveRoleAssignment() {
  if (!selectedUser.value || selectedRoles.value.length === 0) return;

  try {
    // 逐个分配角色
    for (const roleId of selectedRoles.value) {
      const request: AssignRoleRequest = {
        role_id: roleId,
      };
      await rbacStore.assignRoleToUser(selectedUser.value.id, request);
    }

    $q.notify({
      type: "positive",
      message: "角色分配成功",
    });
    showAssignDialog.value = false;
    selectedRoles.value = [];
  } catch (error) {
    console.error("分配角色失败:", error);
    $q.notify({
      type: "negative",
      message: "分配角色失败",
    });
  }
}

/**
 * 打开批量分配对话框
 */
function openBatchAssignDialog() {
  batchSelectedRoles.value = [];
  batchProgress.value = { show: false, value: 0 };
  showBatchAssignDialog.value = true;
}

/**
 * 打开批量移除对话框
 */
function openBatchRemoveDialog() {
  $q.dialog({
    title: "批量移除角色",
    message: "此功能正在开发中",
  });
}

/**
 * 保存批量分配
 */
async function saveBatchAssignment() {
  if (selected.value.length === 0 || batchSelectedRoles.value.length === 0)
    return;

  try {
    batchProgress.value = { show: true, value: 0 };

    const request: BatchAssignRolesRequest = {
      user_ids: selected.value.map((u) => u.id),
      role_ids: batchSelectedRoles.value,
    };

    const response = await rbacStore.batchAssignRoles(request);

    batchProgress.value.value = 1;

    $q.notify({
      type: "positive",
      message: `批量分配完成：成功 ${response.success_count} 个，失败 ${response.failed_count} 个`,
    });

    showBatchAssignDialog.value = false;
    selected.value = [];
    batchSelectedRoles.value = [];
  } catch (error) {
    console.error("批量分配角色失败:", error);
    $q.notify({
      type: "negative",
      message: "批量分配角色失败",
    });
  } finally {
    batchProgress.value.show = false;
  }
}

/**
 * 打开临时角色对话框
 */
function openTemporaryRoleDialog(user: UserWithRoles) {
  selectedUser.value = user;
  temporaryRoleId.value = "";
  temporaryRoleExpires.value = "";
  temporaryRoleReason.value = "";
  showTemporaryRoleDialog.value = true;
}

/**
 * 设置过期时间预设
 */
function setExpiresPreset(hours: number) {
  const expiresAt = new Date();
  expiresAt.setHours(expiresAt.getHours() + hours);
  // 格式化为 datetime-local 输入所需的格式
  temporaryRoleExpires.value = expiresAt.toISOString().slice(0, 16);
}

/**
 * 保存临时角色
 */
async function saveTemporaryRole() {
  if (
    !selectedUser.value ||
    !temporaryRoleId.value ||
    !temporaryRoleExpires.value
  )
    return;

  try {
    const request: SetTemporaryRoleRequest = {
      role_id: temporaryRoleId.value,
      expires_at: new Date(temporaryRoleExpires.value).toISOString(),
      reason: temporaryRoleReason.value || undefined,
    };

    await rbacStore.setTemporaryRole(selectedUser.value.id, request);

    $q.notify({
      type: "positive",
      message: "临时角色设置成功",
    });
    showTemporaryRoleDialog.value = false;
  } catch (error) {
    console.error("设置临时角色失败:", error);
    $q.notify({
      type: "negative",
      message: "设置临时角色失败",
    });
  }
}

/**
 * 查看角色变更历史
 */
async function viewRoleHistory(user: UserWithRoles) {
  selectedUser.value = user;
  await loadRoleHistory();
  showHistoryDialog.value = true;
}

/**
 * 加载角色历史
 */
async function loadRoleHistory() {
  if (!selectedUser.value) return;

  try {
    const response = await rbacStore.fetchUserRoleHistory(
      selectedUser.value.id,
    );
    roleHistory.value = response.history;
  } catch (error) {
    console.error("加载角色历史失败:", error);
    $q.notify({
      type: "negative",
      message: "加载角色历史失败",
    });
  }
}

/**
 * 导出用户列表
 */
function exportUserList() {
  const data = selected.value.map((user) => ({
    用户名: user.username,
    邮箱: user.email,
    角色: user.roles.map((r) => r.name).join(", "),
    最后登录: user.last_login ? formatDate(user.last_login) : "从未登录",
    状态: user.is_online ? "在线" : "离线",
  }));

  const csv = Papa.unparse(data);
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = `用户列表_${new Date().toISOString().slice(0, 10)}.csv`;
  link.click();

  $q.notify({
    type: "positive",
    message: "用户列表已导出",
  });
}

/**
 * 导出历史记录
 */
function exportHistory() {
  const data = filteredHistory.value.map((entry) => ({
    时间: formatDate(entry.timestamp),
    角色名称: entry.role_name,
    操作: entry.action === "assigned" ? "分配" : "移除",
    操作人: entry.operator_name || "-",
    原因: entry.reason || "-",
  }));

  const csv = Papa.unparse(data);
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = `角色变更历史_${selectedUser.value?.username}_${new Date().toISOString().slice(0, 10)}.csv`;
  link.click();

  $q.notify({
    type: "positive",
    message: "历史记录已导出",
  });
}

/**
 * 页面加载时获取数据
 */
onMounted(async () => {
  await Promise.all([rbacStore.fetchRoles(), loadUsers()]);
});
</script>

<style scoped lang="scss">
// 自定义样式
</style>
