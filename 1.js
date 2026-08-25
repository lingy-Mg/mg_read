class UserService {
  constructor(apiClient) {
    this.apiClient = apiClient;
    this.cache = new Map();
  }

  // 测试 1：简单表达式补全
  isValidEmail(email) {
    return 
  }

  // 测试 2：异步请求 + 错误处理
  async getUser(id) {
    const response = await
  }

  // 测试 3：完整 if 逻辑
  parseResponse(response) {
    if (response.status !== 200) {
      
    }
  }

  // 测试 4：数组链式处理
  getActiveUserNames(users) {
    return users
  }

  // 测试 5：完整函数体
  async getActiveUsers(ids) {
    
  }

  // 测试 6：根据注释生成多行逻辑
  // 批量请求用户信息，请求失败的用户跳过
  // 最后只返回 active=true 的用户，并按照 name 排序
  async loadUsers(ids) {
    
  }

  // 测试 7：缓存逻辑
  async getUserWithCache(id) {
    if (this.cache.has(id)) {
      
    }

    const user =
  }

  // 测试 8：复杂数据处理
  // 将用户按照邮箱域名分组
  // 忽略没有邮箱的用户
  // 每组内部按照 id 从小到大排序
  groupUsersByEmailDomain(users) {
    
  }
}