import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'channel_account.dart';

/// A native sign-in form for the account service.
Future<void> showAccountLogin(BuildContext context, ChannelAccount account) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AccountLoginDialog(account: account),
    );

class _AccountLoginDialog extends StatefulWidget {
  const _AccountLoginDialog({required this.account});
  final ChannelAccount account;

  @override
  State<_AccountLoginDialog> createState() => _AccountLoginDialogState();
}

class _AccountLoginDialogState extends State<_AccountLoginDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  String? _temporaryToken;
  String? _error;
  bool _busy = false;
  bool _showPassword = false;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String zh, String en) => _zh ? zh : en;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_temporaryToken == null &&
        (_email.text.trim().isEmpty || _password.text.isEmpty)) {
      setState(
        () => _error = _text('请输入邮箱和密码。', 'Enter your email and password.'),
      );
      return;
    }
    if (_temporaryToken != null && _code.text.trim().isEmpty) {
      setState(
        () => _error = _text('请输入验证码。', 'Enter your verification code.'),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pending = await widget.account.signInWithPassword(
        email: _email.text.trim(),
        password: _password.text,
        temporaryToken: _temporaryToken,
        code: _code.text.trim(),
      );
      if (!mounted) return;
      if (pending != null) {
        _password.clear();
        setState(() => _temporaryToken = pending);
      } else if (widget.account.signedIn) {
        Navigator.of(context).pop();
      } else {
        setState(
          () => _error = _text(
            '登录已失效，请重试。',
            'Sign-in expired. Please try again.',
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSecondFactor = _temporaryToken != null;
    final foreground = theme.colorScheme.onSurface;
    final muted = foreground.withValues(alpha: .7);
    InputDecoration input(String label, IconData icon, {Widget? suffix}) =>
        InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 19),
          suffixIcon: suffix,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
          isDense: true,
        );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 30, 32, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.cloud_outlined,
                      size: 21,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Morning Mist',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _text('关闭', 'Close'),
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Text(
                isSecondFactor
                    ? _text('双重验证', 'Two-step verification')
                    : _text('欢迎回来', 'Welcome back'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isSecondFactor
                    ? _text(
                        '输入身份验证器中的验证码。',
                        'Enter the code from your authenticator app.',
                      )
                    : _text(
                        '登录账号以同步模型和 API 密钥。',
                        'Sign in to sync your models and API keys.',
                      ),
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
              const SizedBox(height: 24),
              if (!isSecondFactor) ...[
                TextField(
                  controller: _email,
                  enabled: !_busy,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.username],
                  textInputAction: TextInputAction.next,
                  decoration: input(_text('邮箱', 'Email'), Icons.mail_outline),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: !_showPassword,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => unawaited(_submit()),
                  decoration: input(
                    _text('密码', 'Password'),
                    Icons.lock_outline,
                    suffix: IconButton(
                      tooltip: _showPassword
                          ? _text('隐藏密码', 'Hide password')
                          : _text('显示密码', 'Show password'),
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 19,
                      ),
                    ),
                  ),
                ),
              ] else
                TextField(
                  controller: _code,
                  enabled: !_busy,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => unawaited(_submit()),
                  decoration: input(
                    _text('验证码', 'Verification code'),
                    Icons.verified_user_outlined,
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                height: 42,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.onPrimary,
                          ),
                        )
                      : Text(
                          isSecondFactor
                              ? _text('验证并登录', 'Verify and sign in')
                              : _text('登录', 'Sign in'),
                        ),
                ),
              ),
              if (isSecondFactor)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _temporaryToken = null;
                          _code.clear();
                          _error = null;
                        }),
                  child: Text(_text('返回邮箱登录', 'Back to email sign-in')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
