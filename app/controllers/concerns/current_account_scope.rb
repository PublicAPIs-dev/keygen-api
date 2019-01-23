module CurrentAccountScope
  extend ActiveSupport::Concern

  def scope_to_current_account!
    account_id = params[:account_id] || params[:id]
    account = Rails.cache.fetch(Account.cache_key(account_id), expires_in: 1.minute) do
      Account.find account_id
    end

    @current_account = account
  end
end
