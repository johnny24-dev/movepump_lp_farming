module movepump_lp_farming::utils {

    use std::vector;
    use std::string;
    use std::type_name;
    use std::string::utf8;
    use std::ascii;
    use sui::coin::Coin;
    use sui::tx_context::TxContext;
    use sui::coin;
    use sui::pay;
    use sui::transfer;

    const EQUAL: u8 = 0;
    const SMALLER: u8 = 1;
    const GREATER: u8 = 2;
    const ERROR_SAME_COIN: u64 = 22;


    const ERROR_INSUFFICIENT_INPUT_AMOUNT: u64 = 0;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 1;
    const ERROR_INSUFFICIENT_AMOUNT: u64 = 2;
    const ERROR_INSUFFICIENT_OUTPOT_AMOUNT: u64 = 3;


    // Performs a comparison of two types after BCS serialization.

    public fun get_smaller_enum(): u8 {
        SMALLER
    }

    public fun get_greater_enum(): u8 {
        GREATER
    }

    public fun get_equal_enum(): u8 {
        EQUAL
    }

    public fun get_amount_out(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64
    ): u64 {
        assert!(amount_in > 0, ERROR_INSUFFICIENT_INPUT_AMOUNT);
        assert!(reserve_in > 0 && reserve_out > 0, ERROR_INSUFFICIENT_LIQUIDITY);

        let amount_in_with_fee = (amount_in as u128) * 9980u128; // 2% to liq
        let numerator = amount_in_with_fee * (reserve_out as u128);
        let denominator = (reserve_in as u128) * 10000u128 + amount_in_with_fee;
        ((numerator / denominator) as u64)
    }

    public fun get_amount_in(
        amount_out: u64,
        reserve_in: u64,
        reserve_out: u64
    ): u64 {
        assert!(amount_out > 0, ERROR_INSUFFICIENT_OUTPOT_AMOUNT);
        assert!(reserve_in > 0 && reserve_out > 0, ERROR_INSUFFICIENT_LIQUIDITY);

        let numerator = (reserve_in as u128) * (amount_out as u128) * 10000u128;
        let denominator = ((reserve_out as u128) - (amount_out as u128)) * 9970u128; // 2% to liq
        (((numerator / denominator) as u64) + 1u64)
    }

    public fun quote(amount_x: u64, reserve_x: u64, reserve_y: u64): u64 {
        assert!(amount_x > 0, ERROR_INSUFFICIENT_AMOUNT);
        assert!(reserve_x > 0 && reserve_y > 0, ERROR_INSUFFICIENT_LIQUIDITY);
        (((amount_x as u128) * (reserve_y as u128) / (reserve_x as u128)) as u64)
    }

    public fun compare_u8_vector(left: vector<u8>, right: vector<u8>): u8 {
        let left_length = vector::length(&left);
        let right_length = vector::length(&right);

        let idx = 0;

        while (idx < left_length && idx < right_length) {
            let left_byte = *vector::borrow(&left, idx);
            let right_byte = *vector::borrow(&right, idx);

            if (left_byte < right_byte) {
                return SMALLER
            } else if (left_byte > right_byte) {
                return GREATER
            };
            idx = idx + 1;
        };

        if (left_length < right_length) {
            SMALLER
        } else if (left_length > right_length) {
            GREATER
        } else {
            EQUAL
        }
    }

    public fun get_lp_name<X,Y>():string::String {

        let lp_name = string::utf8(b"BlueMove-");
        let type_x = type_name::get<X>();
        let type_y = type_name::get<Y>();
        let token_x_name = string::utf8(ascii::into_bytes(type_name::into_string(type_x)));
        let token_y_name = string::utf8(ascii::into_bytes(type_name::into_string(type_y)));
        string::append(&mut lp_name,token_x_name);
        string::append(&mut lp_name,utf8(b"-"));
        string::append(&mut lp_name,token_y_name);
        string::append(&mut lp_name, utf8(b"-LP"));

        lp_name
    }

    public fun get_token_name<X>():string::String{
        let type_x = type_name::get<X>();
        let token_x_name = string::utf8(ascii::into_bytes(type_name::into_string(type_x)));
        token_x_name
    }

    public fun to_bytes<X>():vector<u8>{
        let type_x = type_name::get<X>();
        let x_bytes = ascii::into_bytes(type_name::into_string(type_x));
        x_bytes
    }

    public fun sort_token_type<X, Y>(): bool {

        let x_bytes = to_bytes<X>();
        let y_bytes = to_bytes<Y>();

        let compare_x_y: u8 = compare_u8_vector(x_bytes,y_bytes);
        assert!(compare_x_y != get_equal_enum(), ERROR_SAME_COIN);
        (compare_x_y == get_smaller_enum())
    }

    /// split coin with amount_in and keep remain
    public fun split_and_keep_coin<X>(amount:u64,coins:vector<Coin<X>>,ctx:&mut TxContext):Coin<X>{
        let coins_x = coin::zero<X>(ctx);
        pay::join_vec(&mut coins_x,coins);
        assert!(amount <= coin::value(&coins_x),ERROR_INSUFFICIENT_AMOUNT);
        let coins = coin::split(&mut coins_x,amount,ctx);
        if(coin::value(&coins_x) > 0){
            pay::keep(coins_x,ctx);
        }else{
            coin::destroy_zero(coins_x)
        };
        coins
    }

    public fun destroy_zero_coin<X>(coin:Coin<X>,recipent:address){
        if(coin::value(&coin) > 0){
            transfer::public_transfer(coin,recipent);
        }else{
            coin::destroy_zero(coin)
        }
    }

}
