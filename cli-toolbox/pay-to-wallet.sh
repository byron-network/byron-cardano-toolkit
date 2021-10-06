#!/bin/bash

dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source $dir/etc/config
source $dir/lib/fun.sh
source $dir/lib/lib.sh

show_help() {
  cat << EOF

  Usage: ${0##*/} -s source_addr -d dest_addr -v amount_of_lovelase -k payment_key_path [-h]

  Application description.

  -s source_addr              Source address (pay address).
  -d dest_addr                Destination address.
  -v lovelace                 Amount of lovelace to pay.
  -k payment_key_path         Path to payment key.        
  -h                          Print this help.

EOF
}

source_addr=
dest_addr=
pay_value=
payment_key_path=

while getopts ":s:d:k:v:dh" opt; do

  case $opt in
    s)
      source_addr=$OPTARG
      ;;
    d)
      dest_addr=$OPTARG
      ;;
    v)
      pay_value=$OPTARG
      ;;
    k)
      payment_key_path=$OPTARG
      ;;    
    h)
      show_help
      exit 0
      ;;
    \?)
      echo >&2
      echo "  Invalid option: -$OPTARG" >&2
      show_help
      exit 1
      ;;
    :)
      echo >&2
      echo "  Option -$OPTARG requires an argument" >&2
      show_help
      exit 2
      ;;
    *)
      show_help
      exit 3
      ;;
  esac

done

shift $((OPTIND-1)) # Shift off the options and optional --

required=(source_addr dest_addr pay_value payment_key_path)

for req in ${required[@]}; do
  [[ -z ${!req} ]] && echo && echo "  Please specify $req" && show_help &&  exit 1
done


#----- assert cardano node runs -----

assert_cardano_node_exists

#----- initializing sandbox -----

sandbox_dir=$(pwd)/.pay-to-wallet-script-$(date +"%Y%m%dT%H%M%S")

mkdir -p $sandbox_dir
touch $sandbox_dir/tx.draft
touch $sandbox_dir/tx.signed
cp $payment_key_path $sandbox_dir/payment.skey

#-----  get protocol parameters ----

get_protocol_params > $sandbox_dir/protocol.json

#----- selecting utxo at source wallet address -----

utxo_in=$(get_utxo $source_addr)
utxo_in_value=$(get_utxo_value_at_tx $source_addr $utxo_in)

node_cli transaction build-raw \
  --tx-in $utxo_in \
  --tx-out $source_addr+0 \
  --tx-out $dest_addr+0 \
  --alonzo-era \
  --fee 0 \
  --out-file /out/tx.draft

node_cli transaction calculate-min-fee \
  --tx-body-file /out/tx.draft \
  --tx-in-count 1 \
  --tx-out-count 2 \
  --witness-count 1 \
  --testnet-magic 7 \
  --protocol-params-file /out/protocol.json > $sandbox_dir/fee.txt

fee=$(cat $sandbox_dir/fee.txt | cut -d' ' -f1)

result_balance=$(echo "$utxo_in_value-$fee-$pay_value" | bc)

node_cli transaction build-raw \
  --tx-in $utxo_in \
  --tx-out $source_addr+$result_balance \
  --tx-out $dest_addr+$pay_value \
  --alonzo-era \
  --fee $fee \
  --out-file /out/tx.draft

node_cli transaction sign \
  --tx-body-file /out/tx.draft \
  --signing-key-file /out/payment.skey \
  --testnet-magic $TESTNET_MAGIC \
  --out-file /out/tx.signed

cat <<EOF


      Payment address     : $source_addr 
      Destination address : $dest_addr

      Current balance     : $utxo_in_value
      Pay value           : $pay_value
      Fee                 : $fee
      Result balance      : $result_balance
      
EOF

read -n1 -p 'Submit transaction [y/n] > ' ans < /dev/tty
echo
if [[ $ans == 'y' ]]; then
  echo -e "\nSubmiting transaction...\n"
  node_cli transaction submit \
    --tx-file /out/tx.signed \
    --testnet-magic $TESTNET_MAGIC
  loop_query_utxo $dest_addr
fi

rm -rf $sandbox_dir
