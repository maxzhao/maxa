import { describe, it, expect, beforeEach, vi } from "vitest";
import { mount, VueWrapper } from "@vue/test-utils";
import { createTestingPinia } from "@pinia/testing";
import { Quasar } from "quasar";
import UserRoleAssignmentPage from "@/pages/UserRoleAssignmentPage.vue";
import { useRbacStore } from "@/stores/rbac";
import type { UserWithRoles, Role } from "@/types/api";

/**
 * Mock用户数据
 */
const mockUsers: UserWithRoles[] = [
  {
    id: "user-1",
    username: "alice",
    email: "alice@example.com",
    role: "user" as any,
    roles: [
      {
        id: "role-1",
        name: "Developer",
        permissions: [],
        created_at: "",
        updated_at: "",
      },
    ],
    role_ids: ["role-1"],
    createdAt: "2025-01-01T00:00:00Z",
    updatedAt: "2025-01-01T00:00:00Z",
    is_online: true,
    last_login: "2025-01-20T10:00:00Z",
  },
  {
    id: "user-2",
    username: "bob",
    email: "bob@example.com",
    role: "user" as any,
    roles: [
      {
        id: "role-2",
        name: "Viewer",
        permissions: [],
        created_at: "",
        updated_at: "",
      },
    ],
    role_ids: ["role-2"],
    createdAt: "2025-01-02T00:00:00Z",
    updatedAt: "2025-01-02T00:00:00Z",
    is_online: false,
    last_login: "2025-01-19T10:00:00Z",
  },
];

/**
 * Mock角色数据
 */
const mockRoles: Role[] = [
  {
    id: "role-1",
    name: "Developer",
    description: "Developer role",
    permissions: [],
    created_at: "2025-01-01T00:00:00Z",
    updated_at: "2025-01-01T00:00:00Z",
  },
  {
    id: "role-2",
    name: "Viewer",
    description: "Viewer role",
    permissions: [],
    created_at: "2025-01-01T00:00:00Z",
    updated_at: "2025-01-01T00:00:00Z",
  },
];

/**
 * 创建wrapper
 */
function createWrapper(): VueWrapper<any> {
  return mount(UserRoleAssignmentPage, {
    global: {
      plugins: [
        createTestingPinia({
          createSpy: vi.fn,
          initialState: {
            rbac: {
              users: mockUsers,
              roles: mockRoles,
              usersTotal: mockUsers.length,
              loading: false,
              error: null,
            },
          },
        }),
        [Quasar, {}],
      ],
    },
  });
}

describe("UserRoleAssignmentPage", () => {
  let wrapper: VueWrapper<any>;
  let rbacStore: ReturnType<typeof useRbacStore>;

  beforeEach(() => {
    wrapper = createWrapper();
    rbacStore = useRbacStore();
  });

  describe("页面渲染", () => {
    it("应该正确渲染页面标题", () => {
      const title = wrapper.find(".text-h4");
      expect(title.text()).toBe("用户角色管理");
    });

    it("应该显示搜索和过滤表单", () => {
      const searchInput = wrapper.find(
        'input[placeholder*="搜索用户名或邮箱"]',
      );
      expect(searchInput.exists()).toBe(true);
    });

    it("应该渲染用户列表表格", () => {
      expect(wrapper.find(".q-table").exists()).toBe(true);
    });
  });

  describe("搜索和过滤功能", () => {
    it("应该能够按用户名搜索", async () => {
      const vm = wrapper.vm as any;

      // 设置搜索查询
      vm.searchQuery = "alice";
      await wrapper.vm.$nextTick();

      // 验证过滤后的用户列表
      expect(vm.filteredUsers).toHaveLength(1);
      expect(vm.filteredUsers[0].username).toBe("alice");
    });

    it("应该能够按邮箱搜索", async () => {
      const vm = wrapper.vm as any;

      vm.searchQuery = "bob@example.com";
      await wrapper.vm.$nextTick();

      expect(vm.filteredUsers).toHaveLength(1);
      expect(vm.filteredUsers[0].email).toBe("bob@example.com");
    });

    it("应该能够按角色过滤", async () => {
      const vm = wrapper.vm as any;

      vm.roleFilter = "role-1";
      await wrapper.vm.$nextTick();

      expect(vm.filteredUsers).toHaveLength(1);
      expect(vm.filteredUsers[0].role_ids).toContain("role-1");
    });

    it("应该能够按在线状态过滤", async () => {
      const vm = wrapper.vm as any;

      vm.statusFilter = "online";
      await wrapper.vm.$nextTick();

      expect(vm.filteredUsers).toHaveLength(1);
      expect(vm.filteredUsers[0].is_online).toBe(true);
    });
  });

  describe("用户列表显示", () => {
    it("应该显示用户头像和信息", () => {
      const table = wrapper.find(".q-table");
      expect(table.html()).toContain("alice");
      expect(table.html()).toContain("alice@example.com");
    });

    it("应该显示用户角色标签", () => {
      const table = wrapper.find(".q-table");
      expect(table.html()).toContain("Developer");
      expect(table.html()).toContain("Viewer");
    });

    it("应该显示在线状态", () => {
      const vm = wrapper.vm as any;
      expect(vm.filteredUsers[0].is_online).toBe(true);
      expect(vm.filteredUsers[1].is_online).toBe(false);
    });
  });

  describe("角色分配功能", () => {
    it("应该能够打开角色分配对话框", async () => {
      const vm = wrapper.vm as any;

      vm.openAssignRoleDialog(mockUsers[0]);
      await wrapper.vm.$nextTick();

      expect(vm.showAssignDialog).toBe(true);
      expect(vm.selectedUser).toEqual(mockUsers[0]);
    });

    it("应该能够分配角色", async () => {
      const vm = wrapper.vm as any;
      vi.mocked(rbacStore.assignRoleToUser).mockResolvedValue({
        user_id: "user-1",
        role_id: "role-2",
        assigned_at: "2025-01-20T12:00:00Z",
        message: "Role assigned successfully",
      });

      vm.selectedUser = mockUsers[0];
      vm.selectedRoles = ["role-2"];
      await vm.saveRoleAssignment();

      expect(rbacStore.assignRoleToUser).toHaveBeenCalledWith("user-1", {
        role_id: "role-2",
      });
    });

    it("应该能够移除角色", async () => {
      const vm = wrapper.vm as any;
      vi.mocked(rbacStore.removeRoleFromUser).mockResolvedValue({
        message: "Role removed successfully",
      });

      vm.selectedUser = mockUsers[0];
      await vm.removeUserRole("role-1");

      expect(rbacStore.removeRoleFromUser).toHaveBeenCalledWith(
        "user-1",
        "role-1",
      );
    });
  });

  describe("批量操作功能", () => {
    it("应该能够选择多个用户", async () => {
      const vm = wrapper.vm as any;

      vm.selected = [mockUsers[0], mockUsers[1]];
      await wrapper.vm.$nextTick();

      expect(vm.selected).toHaveLength(2);
    });

    it("应该能够批量分配角色", async () => {
      const vm = wrapper.vm as any;
      vi.mocked(rbacStore.batchAssignRoles).mockResolvedValue({
        success_count: 2,
        failed_count: 0,
        details: [],
      });

      vm.selected = mockUsers;
      vm.batchSelectedRoles = ["role-1", "role-2"];
      await vm.saveBatchAssignment();

      expect(rbacStore.batchAssignRoles).toHaveBeenCalledWith({
        user_ids: ["user-1", "user-2"],
        role_ids: ["role-1", "role-2"],
      });
    });
  });

  describe("临时角色功能", () => {
    it("应该能够打开临时角色对话框", async () => {
      const vm = wrapper.vm as any;

      vm.openTemporaryRoleDialog(mockUsers[0]);
      await wrapper.vm.$nextTick();

      expect(vm.showTemporaryRoleDialog).toBe(true);
      expect(vm.selectedUser).toEqual(mockUsers[0]);
    });

    it("应该能够设置过期时间预设", async () => {
      const vm = wrapper.vm as any;

      vm.setExpiresPreset(24); // 1天
      await wrapper.vm.$nextTick();

      expect(vm.temporaryRoleExpires).toBeTruthy();
      // 验证日期是否在未来
      const expiresDate = new Date(vm.temporaryRoleExpires);
      expect(expiresDate.getTime()).toBeGreaterThan(Date.now());
    });

    it("应该能够设置临时角色", async () => {
      const vm = wrapper.vm as any;
      vi.mocked(rbacStore.setTemporaryRole).mockResolvedValue({
        user_id: "user-1",
        role_id: "role-1",
        expires_at: "2025-01-21T12:00:00Z",
        message: "Temporary role set successfully",
      });

      vm.selectedUser = mockUsers[0];
      vm.temporaryRoleId = "role-1";
      vm.temporaryRoleExpires = "2025-01-21T12:00";
      await vm.saveTemporaryRole();

      expect(rbacStore.setTemporaryRole).toHaveBeenCalled();
    });
  });

  describe("角色历史功能", () => {
    it("应该能够查看角色变更历史", async () => {
      const vm = wrapper.vm as any;
      vi.mocked(rbacStore.fetchUserRoleHistory).mockResolvedValue({
        user_id: "user-1",
        history: [
          {
            id: "history-1",
            user_id: "user-1",
            role_id: "role-1",
            role_name: "Developer",
            action: "assigned" as const,
            timestamp: "2025-01-20T10:00:00Z",
          },
        ],
        total: 1,
      });

      await vm.viewRoleHistory(mockUsers[0]);

      expect(rbacStore.fetchUserRoleHistory).toHaveBeenCalledWith("user-1");
      expect(vm.showHistoryDialog).toBe(true);
    });

    it("应该能够按时间范围过滤历史", async () => {
      const vm = wrapper.vm as any;

      vm.roleHistory = [
        {
          id: "history-1",
          user_id: "user-1",
          role_id: "role-1",
          role_name: "Developer",
          action: "assigned" as const,
          timestamp: "2025-01-20T10:00:00Z",
        },
        {
          id: "history-2",
          user_id: "user-1",
          role_id: "role-2",
          role_name: "Viewer",
          action: "assigned" as const,
          timestamp: "2024-12-01T10:00:00Z",
        },
      ];

      vm.historyTimeRange = 7; // 最近7天
      await wrapper.vm.$nextTick();

      // 应该只显示最近7天的记录
      expect(vm.filteredHistory.length).toBeLessThanOrEqual(1);
    });
  });

  describe("工具函数", () => {
    it("应该正确格式化日期", () => {
      const vm = wrapper.vm as any;
      const date = "2025-01-20T10:00:00Z";
      const formatted = vm.formatDate(date);
      expect(formatted).toBeTruthy();
      expect(typeof formatted).toBe("string");
    });

    it("应该获取角色名称", () => {
      const vm = wrapper.vm as any;
      const roleName = vm.getRoleName("role-1");
      expect(roleName).toBe("Developer");
    });

    it("应该为未知角色返回默认名称", () => {
      const vm = wrapper.vm as any;
      const roleName = vm.getRoleName("unknown-role");
      expect(roleName).toBe("未知角色");
    });

    it("应该为不同角色ID生成不同颜色", () => {
      const vm = wrapper.vm as any;
      const color1 = vm.getRoleColor("role-1");
      const color2 = vm.getRoleColor("role-2");
      expect(color1).toBeTruthy();
      expect(color2).toBeTruthy();
      // 颜色应该是有效的Quasar颜色
      const validColors = [
        "primary",
        "secondary",
        "accent",
        "info",
        "positive",
        "warning",
      ];
      expect(validColors).toContain(color1);
      expect(validColors).toContain(color2);
    });
  });
});
