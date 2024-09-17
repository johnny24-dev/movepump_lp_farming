module movepump_lp_farming::farming {
    use sui::event;
    use sui::coin;
    use sui::tx_context::TxContext;
    use sui::transfer::{public_share_object, public_transfer};
    use sui::tx_context;
    use sui::coin::Coin;
    use sui::object::{UID, ID};
    use sui::object;
    use sui::clock::Clock;
    use sui::clock;
    use std::string::String;
    use std::u64::max;
    use movepump_lp_farming::utils::{get_token_name};
    use bluemove_dex::swap::LSP;
    use move_pump::move_pump::Configuration;
    use move_pump::move_pump;
    use sui::dynamic_field;
    use sui::sui::SUI;
    use sui::table;
    use sui::table::Table;
    use sui::table_vec::TableVec;
    //
    // Errors.
    //

    const ERROR_NOT_ADMIN: u64 = 0;
    const ERROR_COIN_NOT_PUBLISHED: u64 = 1;
    const ERROR_INVALID_LP_TOKEN: u64 = 2;
    const ERROR_LP_TOKEN_EXIST: u64 = 3;
    const ERROR_WITHDRAW_INSUFFICIENT: u64 = 4;
    const ERROR_INVALID_MOVE_RATE: u64 = 5;
    const ERROR_PID_NOT_EXIST: u64 = 6;
    const ERROR_COIN_NOT_REGISTERED: u64 = 7;
    const ERROR_MOVE_REWARD_OVERFLOW: u64 = 8;
    const ERROR_INVALID_COIN_DECIMAL: u64 = 9;
    const ERROR_POOL_USER_INFO_NOT_EXIST: u64 = 10;
    const ERROR_ZERO_ACCOUNT: u64 = 11;
    const ERROR_UPKEEP_ELAPSED_OVER_CAP: u64 = 12;
    const ERROR_INPUT_BALANCE: u64 = 13;
    const E_INVALID_VERSION:u64 = 14;
    const E_POOL_STILL_LIVE:u64 = 15;
    const E_POOL_EXPIRED:u64 = 16;
    //
    // CONSTANTS.
    //

    const DEV: address = @0x049cc391ab4d3503e03dbb24c4f9e28f3cdd2ddf8a459e0d43012c3868ffefa1;
    const ADMIN:address = @0x049cc391ab4d3503e03dbb24c4f9e28f3cdd2ddf8a459e0d43012c3868ffefa1;
    const UPKEEP_ELAPSED_HARD_CAP: u64 = 30 * 24 * 60 * 60 ; // 1 month by seconds
    const SUI_DEFAULT_DECIMAL: u8 = 9;
    const TOTAL_MOVE_RATE_PRECISION: u64 = 100000;
    const INITIAL_REGULAR_MOVE_RATE_PRECISION: u64 = 40000;
    const INITIAL_SPECIAL_MOVE_RATE_PRECISION: u64 = 60000;
    const ACC_MOVE_PRECISION: u128 = 1000000000000;
    const MAX_U64: u128 = 18446744073709551615;
    const MAX_U128: u128 = 340282366920938463463374607431768211455;
    const MAX_U64_: u64 = 18446744073709551615;
    const VERSION:u64 = 1;

    /// Metadata
    struct FarmingData has key, store {
        id:UID,
        admin: address,
        version:u64
    }

    struct PoolTime has store, drop, copy {
        lp_type:String,
        end_time:u64
    }


    struct StakingPool<phantom LpType, phantom RewardType> has key, store {
        id:UID,
        user_infor:Table<address,UserInfo>,
        coin_lp:Coin<LpType>,
        reward_coin:Coin<RewardType>,
        total_user:u64,
        total_amount: u128,
        acc_x_per_share: u128,
        x_per_second: u64,
        last_reward_timestamp: u64,
        last_upkeep_timestamp: u64,
        end_timestamp: u64,
        reward_type:String,
    }

    struct UserInfo has store, copy, drop {
        amount: u128,
        ///   reward_debt is a 'accounting' field used for distribute move reward to each user in the pool.
        ///
        ///   pending_move_reward = (user.share * pool.acc_move_per_share) - user.reward_debt
        ///
        ///   Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        ///   1. 'update_pool': The pool info will be updated, that means 'acc_move_per_share' and 'last_reward_timestamp' updated
        ///   2. 'settle_pending_move': contract will send all pending MOVE to the user address.
        ///   3. 'reset reward_debt': user.reward_debt = user.share * pool.acc_move_per_share
        ///   it means that all the MOVE rewards of the user have been taken away at this moment.
        ///
        reward_x_debt: u128
    }

    /// Event emitted when coin is deposited into an pool.
    struct DepositEvent has copy ,drop, store {
        user: address,
        pid: ID,
        amount: u64,
        lp_type:String
    }

    /// Event emitted when coin is withdrawn from an pool.
    struct WithdrawEvent has copy, drop, store {
        user: address,
        pid: ID,
        amount: u64,
        lp_type:String
    }

    struct CreateStakingPoolEvent has copy, drop, store {
        pid:ID,
        lp_type:String,
        reward_type:String,
        created_time:u64,
        end_time:u64,
        user:address
    }

    struct AddRewardPoolEvent has copy, drop, store {
        pid:ID,
        lp_type:String,
        reward_type:String,
        amount_reward:u64,
        reward_per_second:u64,
        user:address
    }

    struct UpdatePoolEvent has copy, store, drop {
        pid:ID,
        last_reward_timestamp: u64,
        lp_supply: u128,
        acc_x_per_share: u128,
    }

    struct GetUserInfor has copy, store, drop {
        stake_amount:u128,
        reward_debt:u128
    }

    fun init(ctx:&mut TxContext) {
        // let sender_address = tx_context::sender(ctx);
        // assert!(sender_address == ADMIN, ERROR_NOT_ADMIN);
        // let current_timestamp = clock::timestamp_ms(clock) / 1000;

        public_share_object(FarmingData {
            id:object::new(ctx),
            admin: ADMIN,
            version:VERSION
        });
    }

    fun assert_version(
        current_verion:u64
    ){
        assert!(current_verion == VERSION, E_INVALID_VERSION);
    }

    public entry fun migrate_version(
        config:&mut FarmingData,
        new_version:u64,
        ctx:&mut TxContext
    ){
        let sender = tx_context::sender(ctx);
        assert!(config.admin == sender || sender == DEV, ERROR_NOT_ADMIN);
        config.version = new_version;
    }

    public entry fun set_admin(
        farming_data:&mut FarmingData,
        new_admin: address,
        ctx:&mut TxContext
    ) {
        let sender_address = tx_context::sender(ctx);
        assert!(new_admin != @0x0, ERROR_ZERO_ACCOUNT);
        assert!(sender_address == farming_data.admin || sender_address == DEV, ERROR_NOT_ADMIN);
        farming_data.admin = new_admin;
    }


    public entry fun emergency_withdraw_reward<X>(
        staking_pool:&mut StakingPool<LSP<SUI,X>,X>,
        ctx:&mut TxContext){
        let sender_addr = tx_context::sender(ctx);
        assert!(sender_addr == ADMIN || sender_addr == DEV, ERROR_NOT_ADMIN);

        let value_x = coin::value(&staking_pool.reward_coin);
        if(value_x > 0){
            let coin_x = coin::split(&mut staking_pool.reward_coin, value_x,ctx);
            public_transfer(coin_x,ADMIN);
        };

    }

    public entry fun deposit<X>(
        config:&FarmingData,
        staking_pool:&mut StakingPool<LSP<SUI,X>,X>,
        lp_coin:Coin<LSP<SUI,X>>,
        clock:&Clock,
        ctx:&mut TxContext
    ){
        let sender_addr = tx_context::sender(ctx);
        let token_name = get_token_name<LSP<SUI,X>>();
        let amount = coin::value(&lp_coin);

        assert_version(config.version);
        let current_time = clock::timestamp_ms(clock) / 1000;
        assert!(staking_pool.end_timestamp > current_time, E_POOL_EXPIRED);

        let pid = object::id(staking_pool);
        update_pool(staking_pool,clock,ctx);

        if (!table::contains(&staking_pool.user_infor,sender_addr)) {
            table::add(&mut staking_pool.user_infor,sender_addr,UserInfo{
                amount:0,
                reward_x_debt:0
            });
            staking_pool.total_user = staking_pool.total_user + 1;
        };
        let user_info =  table::borrow_mut<address, UserInfo>(&mut staking_pool.user_infor, sender_addr);
        if (user_info.amount > 0) {
            let pending_x = ((user_info.amount * staking_pool.acc_x_per_share) / ACC_MOVE_PRECISION - user_info.reward_x_debt as u64);
            distributed_reward<X>(&mut staking_pool.reward_coin,pending_x,sender_addr,ctx);
        };

        if(amount == 0){
            coin::destroy_zero(lp_coin);
        }else{
            coin::join(&mut staking_pool.coin_lp,lp_coin);
            user_info.amount = user_info.amount + (amount as u128);
            staking_pool.total_amount = staking_pool.total_amount + (amount as u128);
        };
        user_info.reward_x_debt = user_info.amount * staking_pool.acc_x_per_share / ACC_MOVE_PRECISION;
        event::emit(
            DepositEvent {
                user: sender_addr,
                pid,
                amount,
                lp_type:token_name
            }
        );
    }

    public entry fun withdraw<X>(
        config:&FarmingData,
        staking_pool:&mut StakingPool<LSP<SUI,X>,X>,
        amount: u64,
        clock:&Clock,
        ctx:&mut TxContext
    ) {
        let lp_name = get_token_name<LSP<SUI,X>>();
        let pool_id = object::id(staking_pool);
        let sender_addr = tx_context::sender(ctx);
        assert_version(config.version);
        update_pool(staking_pool,clock,ctx);
        let user_info = table::borrow_mut<address,UserInfo>(&mut staking_pool.user_infor,sender_addr);
        assert!(user_info.amount >= (amount as u128), ERROR_WITHDRAW_INSUFFICIENT);

        // Send pending move
        let pending_x = ((user_info.amount * staking_pool.acc_x_per_share) / ACC_MOVE_PRECISION - user_info.reward_x_debt as u64);
        assert!(pending_x <= MAX_U64_, ERROR_MOVE_REWARD_OVERFLOW);
        distributed_reward<X>(&mut staking_pool.reward_coin,pending_x,sender_addr,ctx);

        if (amount > 0) {
            user_info.amount = user_info.amount - (amount as u128);
            let coin_lp = coin::split(&mut staking_pool.coin_lp, amount,ctx);
            public_transfer(coin_lp,sender_addr);
        };
        user_info.reward_x_debt = user_info.amount * staking_pool.acc_x_per_share / ACC_MOVE_PRECISION;
        staking_pool.total_amount = staking_pool.total_amount - (amount as u128);

        event::emit(
            WithdrawEvent {
                user: sender_addr,
                pid:pool_id,
                amount,
                lp_type:lp_name
            }
        );
    }

    public entry fun create_staking_pool<CoinType>(
        move_pump_config:&Configuration,
        config:&mut FarmingData,
        clock:&Clock,
        ctx:&mut TxContext
    ){
        let sender_address = tx_context::sender(ctx);
        let type_info = get_token_name<CoinType>();
        assert_version(config.version);
        let current_timestamp = clock::timestamp_ms(clock) / 1000;
        let end_time = current_timestamp + (60 * 60 * 24 * 30);
        let lp_type = get_token_name<LSP<SUI,CoinType>>();

        move_pump::asert_pool_not_completed<CoinType>(move_pump_config,ctx);

        if (!dynamic_field::exists_<String>(&config.id,type_info)){
            let pool_create_detail = PoolTime {
                lp_type,
                end_time
            };
            dynamic_field::add(&mut config.id,type_info,pool_create_detail);
        }else {
            let end_pool_detail = dynamic_field::borrow_mut<String,PoolTime>(&mut config.id,type_info);
            assert!(current_timestamp > end_pool_detail.end_time, E_POOL_STILL_LIVE);
            end_pool_detail.end_time = end_time;
        };
        let staking_pool = StakingPool<LSP<SUI,CoinType>,CoinType>{
            id:object::new(ctx),
            user_infor:table::new(ctx),
            coin_lp:coin::zero<LSP<SUI,CoinType>>(ctx),
            reward_coin:coin::zero<CoinType>(ctx),
            total_user:0,
            total_amount: 0,
            acc_x_per_share: 0,
            x_per_second: 0,
            last_reward_timestamp: current_timestamp,
            last_upkeep_timestamp: current_timestamp,
            end_timestamp: end_time,
            reward_type:type_info,
        };

        let pool_id = object::id(&staking_pool);
        public_share_object(staking_pool);

        event::emit(CreateStakingPoolEvent{
            pid:pool_id,
            lp_type,
            reward_type:type_info,
            created_time:current_timestamp,
            end_time,
            user:sender_address
        })

    }

    public entry fun set_pool<X>(
        farming_data:&mut FarmingData,
        staking_pool:&mut StakingPool<LSP<SUI,X>,X>,
        x_per_second:u64,
        clock:&Clock,
        ctx:&mut TxContext
    ){
        let sender_address = tx_context::sender(ctx);
        assert!(sender_address == farming_data.admin || sender_address == DEV, ERROR_NOT_ADMIN);
        update_pool(staking_pool,clock,ctx);
        staking_pool.x_per_second = x_per_second;

    }

    public entry fun update_pool<X>(
        staking_pool:&mut StakingPool<LSP<SUI,X>,X>,
        clock:&Clock,
        _ctx:&mut TxContext){
        let (x_reward, acc_x_per_share) = calc_reward(staking_pool,clock);
        let current_timestamp = clock::timestamp_ms(clock) / 1000;
        if (x_reward > 0) {
            staking_pool.acc_x_per_share = acc_x_per_share;
        };
        if (current_timestamp > staking_pool.last_reward_timestamp) {
            // Timestamp will always be updated no matter ,move_reward is 0 or not
            staking_pool.last_reward_timestamp = current_timestamp;
            let pool_id = object::id(staking_pool);
            event::emit(
                UpdatePoolEvent {
                    pid:pool_id,
                    last_reward_timestamp: current_timestamp,
                    lp_supply: staking_pool.total_amount,
                    acc_x_per_share: staking_pool.acc_x_per_share,
                }
            );
        };
    }

    public entry fun add_reward_for_pool<X>(
        staking_pool:&mut StakingPool<LSP<SUI,X>,X>,
        coin_x:Coin<X>,
        ctx:&mut TxContext
    ){
        let sender_address = tx_context::sender(ctx);
        let lp_type = get_token_name<LSP<SUI,X>>();
        let reward_type = get_token_name<X>();
        let pool_id = object::id(staking_pool);
        let reward_amount = coin::value(&coin_x);
        coin::join(&mut staking_pool.reward_coin,coin_x);
        // update reward_per_second
        let total_reward = coin::value(&staking_pool.reward_coin);
        let reward_second = total_reward / (60*60*24*30);
        staking_pool.x_per_second = reward_second;
        staking_pool.reward_type = get_token_name<X>();

        event::emit(
            AddRewardPoolEvent{
                pid:pool_id,
                lp_type,
                reward_type,
                amount_reward:reward_amount,
                reward_per_second:reward_second,
                user:sender_address
            }
        )

    }


    public fun pending_move<X>(
        staking_pool:&StakingPool<LSP<SUI,X>,X>,
        clock:&Clock,
        user: address
    ): u64 {
        let (_,acc_x_per_share) = calc_reward(staking_pool,clock);
        let user_info = table::borrow<address,UserInfo>(&staking_pool.user_infor,user);
        ((user_info.amount * acc_x_per_share / ACC_MOVE_PRECISION - user_info.reward_x_debt) as u64)
    }

    fun distributed_reward<X>(
        reward_coin:&mut Coin<X>,
        pending_x:u64,
        sender_addr:address,
        ctx:&mut TxContext
    ){

                // for X
                let balance = coin::value<X>(reward_coin);
                if (balance < pending_x) {
                    pending_x = balance;
                };
                let coin_reward = coin::split(reward_coin, pending_x,ctx);
                public_transfer(coin_reward,sender_addr);
    }

    fun calc_reward<X>(
        staking_pool:&StakingPool<LSP<SUI,X>,X>,
        clock:&Clock,
    ): (u64, u128){

        let x_reward:u128 = 0;
        let acc_x_per_share = staking_pool.acc_x_per_share;

        let current_timestamp = clock::timestamp_ms(clock) /1000;

        if (current_timestamp > staking_pool.last_reward_timestamp) {
            let supply = staking_pool.total_amount;
            let multiplier = if (staking_pool.end_timestamp <= staking_pool.last_reward_timestamp) {
                0
            } else if (current_timestamp <= staking_pool.end_timestamp) {
                // if 'mass_update_pools' is ignored on any function which should be called,like 'upkeep',
                // should choose the max timestamp as 'last_reward_timestamp'.
                current_timestamp - max(staking_pool.last_reward_timestamp, staking_pool.last_upkeep_timestamp)
            } else {
                staking_pool.end_timestamp - max(staking_pool.last_reward_timestamp, staking_pool.last_upkeep_timestamp)
            };
            if (supply > 0 ) {
                x_reward = ((multiplier as u128) * (staking_pool.x_per_second as u128));
                acc_x_per_share = (staking_pool.acc_x_per_share) + (x_reward * ACC_MOVE_PRECISION) / supply;
                assert!(x_reward <= MAX_U64 && acc_x_per_share <= MAX_U128, ERROR_MOVE_REWARD_OVERFLOW);
            };
        };

        ((x_reward as u64), acc_x_per_share)
    }

    public fun get_user_infor<CoinType>(
        staking_pool:&StakingPool<LSP<SUI,CoinType>,CoinType>,
        user:address,
        _ctx:&mut TxContext
    ){
        let user_info = table::borrow(&staking_pool.user_infor,user);
        event::emit(GetUserInfor{
            stake_amount:user_info.amount,
            reward_debt:user_info.reward_x_debt
        })
    }
}
