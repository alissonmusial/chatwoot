import {
  hasPermissions,
  getUserPermissions,
  getCurrentAccount,
} from './permissionsHelper';

import {
  ROLES,
  CONVERSATION_PERMISSIONS,
  CONTACT_PERMISSIONS,
  REPORTS_PERMISSIONS,
  PORTAL_PERMISSIONS,
} from 'dashboard/constants/permissions.js';

export const routeIsAccessibleFor = (route, userPermissions = []) => {
  const { meta: { permissions: routePermissions = [] } = {} } = route;
  return hasPermissions(routePermissions, userPermissions);
};

export const defaultRedirectPage = (to, permissions) => {
  const { accountId } = to.params;

  const permissionRoutes = [
    {
      permissions: [...ROLES, ...CONVERSATION_PERMISSIONS],
      path: 'dashboard',
    },
    { permissions: [CONTACT_PERMISSIONS], path: 'contacts' },
    { permissions: [REPORTS_PERMISSIONS], path: 'reports/overview' },
    { permissions: [PORTAL_PERMISSIONS], path: 'portals' },
  ];

  const route = permissionRoutes.find(({ permissions: routePermissions }) =>
    hasPermissions(routePermissions, permissions)
  );

  return `accounts/${accountId}/${route ? route.path : 'dashboard'}`;
};

const validateActiveAccountRoutes = (to, user) => {
  // If the current account is active, then check for the route permissions
  const accountDashboardURL = `accounts/${to.params.accountId}/dashboard`;

  // If the user is trying to access suspended route, redirect them to dashboard
  if (to.name === 'account_suspended') {
    return accountDashboardURL;
  }

  const userPermissions = getUserPermissions(user, to.params.accountId);

  const isAccessible = routeIsAccessibleFor(to, userPermissions);
  // If the route is not accessible for the user, return to dashboard screen
  return isAccessible ? null : defaultRedirectPage(to, userPermissions);
};

const BILLING_REQUIRED_ROUTE_PREFIXES = ['captain_'];

const requiresSubscriptionForRoute = routeName =>
  BILLING_REQUIRED_ROUTE_PREFIXES.some(prefix => routeName?.startsWith(prefix));

const isQuotaUnavailable = limit => {
  if (!limit) return false;

  const { total_count: totalCount, current_available: currentAvailable } =
    limit;

  if (typeof totalCount === 'number') {
    if (totalCount === 0) {
      return true;
    }

    if (typeof currentAvailable === 'number') {
      return currentAvailable <= 0;
    }
  }

  return false;
};

const shouldForceBilling = account => {
  if (!account) return false;

  const subscription = account.subscription || {};
  const planName =
    subscription.plan ||
    account.plan_name ||
    account.custom_attributes?.plan_name;
  const status = subscription.status;
  const evolutionLimit = account.limits?.evolution?.sessions;
  const quotaUnavailable = isQuotaUnavailable(evolutionLimit);

  if (!planName || planName === 'Hacker') {
    return true;
  }

  const activeStatuses = ['active', 'trialing', 'past_due'];

  if (!status || !activeStatuses.includes(status)) {
    return true;
  }

  if (status === 'past_due' && subscription.endsOn) {
    const renewalDate = new Date(subscription.endsOn);
    if (Number.isNaN(renewalDate.getTime())) {
      return false;
    }
    return renewalDate < new Date();
  }

  return quotaUnavailable;
};

export const validateLoggedInRoutes = (to, user, store) => {
  const currentAccount = getCurrentAccount(user, Number(to.params.accountId));
  // If current account is missing, either user does not have
  // access to the account or the account is deleted, return to login screen
  if (!currentAccount) {
    return `app/login`;
  }

  const getAccountFromStore = store?.getters?.['accounts/getAccount'];
  const accountRecordFromStore =
    typeof getAccountFromStore === 'function'
      ? getAccountFromStore(Number(to.params.accountId))
      : {};

  const hydratedAccount = {
    ...currentAccount,
    ...accountRecordFromStore,
  };

  const isCurrentAccountActive = hydratedAccount.status === 'active';

  if (isCurrentAccountActive) {
    if (
      requiresSubscriptionForRoute(to.name) &&
      shouldForceBilling(hydratedAccount)
    ) {
      return `accounts/${to.params.accountId}/settings/billing`;
    }
    return validateActiveAccountRoutes(to, user);
  }

  // If the current account is not active, then redirect the user to the suspended screen
  if (to.name !== 'account_suspended') {
    return `accounts/${to.params.accountId}/suspended`;
  }

  // Proceed to the route if none of the above conditions are met
  return null;
};

export const isAConversationRoute = (
  routeName,
  includeBase = false,
  includeExtended = true
) => {
  const baseRoutes = [
    'home',
    'conversation_mentions',
    'conversation_unattended',
    'inbox_dashboard',
    'label_conversations',
    'team_conversations',
    'folder_conversations',
    'conversation_participating',
  ];
  const extendedRoutes = [
    'inbox_conversation',
    'conversation_through_mentions',
    'conversation_through_unattended',
    'conversation_through_inbox',
    'conversations_through_label',
    'conversations_through_team',
    'conversations_through_folders',
    'conversation_through_participating',
  ];

  const routes = [
    ...(includeBase ? baseRoutes : []),
    ...(includeExtended ? extendedRoutes : []),
  ];

  return routes.includes(routeName);
};

export const getConversationDashboardRoute = routeName => {
  switch (routeName) {
    case 'inbox_conversation':
      return 'home';
    case 'conversation_through_mentions':
      return 'conversation_mentions';
    case 'conversation_through_unattended':
      return 'conversation_unattended';
    case 'conversations_through_label':
      return 'label_conversations';
    case 'conversations_through_team':
      return 'team_conversations';
    case 'conversations_through_folders':
      return 'folder_conversations';
    case 'conversation_through_participating':
      return 'conversation_participating';
    case 'conversation_through_inbox':
      return 'inbox_dashboard';
    default:
      return null;
  }
};

export const isAInboxViewRoute = (routeName, includeBase = false) => {
  const baseRoutes = ['inbox_view'];
  const extendedRoutes = ['inbox_view_conversation'];
  const routeNames = includeBase
    ? [...baseRoutes, ...extendedRoutes]
    : extendedRoutes;
  return routeNames.includes(routeName);
};

export const isNotificationRoute = routeName =>
  routeName === 'notifications_index';
