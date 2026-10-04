/// 一个能力的认证要求。
///
/// Provider 对每个能力声明自己的认证要求；能力选择与认证配置彼此正交：
/// 选择决定「用哪个 Provider 的哪个能力」，认证要求由被选中的 Provider 声明。
sealed class OnlineMusicProviderAuth {
  const OnlineMusicProviderAuth();
}

/// 该能力的请求不需要任何凭据：不读取凭据、不注入参数。
final class OnlineMusicNoAuth extends OnlineMusicProviderAuth {
  const OnlineMusicNoAuth();
}

/// 该能力的请求使用 Provider 自己绑定的凭据，并作为查询参数注入。
final class OnlineMusicApiKeyAuth extends OnlineMusicProviderAuth {
  const OnlineMusicApiKeyAuth({
    this.parameterName = defaultOnlineMusicCredentialParameter,
  });

  final String parameterName;
}

const defaultOnlineMusicCredentialParameter = 'apikey';
